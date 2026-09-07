import Foundation

public struct RefreshFailure: Error, Equatable, Sendable {
  public let description: String

  public init(_ error: any Error) {
    description = String(describing: error)
  }
}

public enum RefreshState<Value: Sendable>: Sendable {
  case idle
  case refreshing(previous: Value?)
  case switching(previous: Value?)
  case current(Value)
  case stale(Value, failure: RefreshFailure)
  case failed(RefreshFailure)
}

extension RefreshState: Equatable where Value: Equatable {}

public enum RefreshCoordinatorError: Error, Equatable, Sendable {
  case stopped
}

public actor RefreshCoordinator<Value: Sendable> {
  public typealias Operation = @Sendable () async throws -> Value

  private struct SwitchRequest {
    let operation: Operation
    let continuation: CheckedContinuation<Value, any Error>
  }

  private enum PendingOperation {
    case refresh
    case providerSwitch(SwitchRequest)
  }

  private enum ActiveOperation {
    case refresh
    case providerSwitch(CheckedContinuation<Value, any Error>)
  }

  private let clock: any RefreshClock
  private let interval: Duration
  private let refreshOperation: Operation

  private var state: RefreshState<Value> = .idle
  private var lastSettledState: RefreshState<Value> = .idle
  private var lastGoodValue: Value?
  private var observers: [UUID: AsyncStream<RefreshState<Value>>.Continuation] = [:]
  private var pendingOperations: [PendingOperation] = []
  private var activeOperation: ActiveOperation?
  private var activeOperationID: UUID?
  private var providerTask: Task<Void, Never>?
  private var schedulerTask: Task<Void, Never>?
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var started = false

  public init(
    clock: any RefreshClock,
    interval: Duration = .seconds(300),
    refresh: @escaping Operation
  ) {
    self.clock = clock
    self.interval = interval
    refreshOperation = refresh
  }

  public func start() {
    guard !started else {
      return
    }

    started = true
    enqueueRefresh()

    let clock = self.clock
    let interval = self.interval
    schedulerTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await clock.sleep(for: interval)
        } catch {
          return
        }

        guard !Task.isCancelled else {
          return
        }
        await self?.requestRefreshFromScheduler()
      }
    }
  }

  public func requestRefresh() {
    guard started else {
      return
    }
    enqueueRefresh()
  }

  public func performSwitch(_ operation: @escaping Operation) async throws -> Value {
    guard started else {
      throw RefreshCoordinatorError.stopped
    }

    return try await withCheckedThrowingContinuation { continuation in
      pendingOperations.append(
        .providerSwitch(
          SwitchRequest(operation: operation, continuation: continuation)
        )
      )
      runNextOperationIfNeeded()
    }
  }

  public func currentState() -> RefreshState<Value> {
    state
  }

  public func stateChanges() -> AsyncStream<RefreshState<Value>> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: RefreshState<Value>.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    observers[id] = continuation
    continuation.yield(state)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id: id) }
    }
    return stream
  }

  public func waitUntilIdle() async {
    guard activeOperation == nil, pendingOperations.isEmpty else {
      await withCheckedContinuation { continuation in
        idleWaiters.append(continuation)
      }
      return
    }
  }

  public func stop() async {
    guard started || schedulerTask != nil || providerTask != nil || !observers.isEmpty else {
      return
    }

    started = false
    let scheduler = schedulerTask
    let provider = providerTask
    schedulerTask = nil
    providerTask = nil
    scheduler?.cancel()
    provider?.cancel()

    let active = activeOperation
    activeOperation = nil
    activeOperationID = nil
    let pending = pendingOperations
    pendingOperations.removeAll()

    if case .providerSwitch(let continuation) = active {
      continuation.resume(throwing: CancellationError())
    }
    for operation in pending {
      if case .providerSwitch(let request) = operation {
        request.continuation.resume(throwing: CancellationError())
      }
    }

    if active != nil {
      publish(lastSettledState)
    }
    resumeIdleWaiters()
    let activeObservers = Array(observers.values)
    observers.removeAll()
    for observer in activeObservers {
      observer.finish()
    }

    await scheduler?.value
    await provider?.value
  }

  private func requestRefreshFromScheduler() {
    guard started else {
      return
    }
    enqueueRefresh()
  }

  private func enqueueRefresh() {
    if activeOperation != nil {
      guard
        !pendingOperations.contains(where: { operation in
          if case .refresh = operation {
            return true
          }
          return false
        })
      else {
        return
      }
      pendingOperations.append(.refresh)
      return
    }

    pendingOperations.append(.refresh)
    runNextOperationIfNeeded()
  }

  private func runNextOperationIfNeeded() {
    guard activeOperation == nil, !pendingOperations.isEmpty else {
      return
    }

    let pending = pendingOperations.removeFirst()
    let id = UUID()
    activeOperationID = id

    let operation: Operation
    switch pending {
    case .refresh:
      activeOperation = .refresh
      operation = refreshOperation
      publish(.refreshing(previous: lastGoodValue))
    case .providerSwitch(let request):
      activeOperation = .providerSwitch(request.continuation)
      operation = request.operation
      publish(.switching(previous: lastGoodValue))
    }

    providerTask = Task { [weak self] in
      let result: Result<Value, any Error>
      do {
        result = .success(try await operation())
      } catch {
        result = .failure(error)
      }
      await self?.operationFinished(id: id, result: result)
    }
  }

  private func operationFinished(id: UUID, result: Result<Value, any Error>) {
    guard activeOperationID == id, let completedOperation = activeOperation else {
      return
    }

    activeOperationID = nil
    activeOperation = nil
    providerTask = nil

    switch result {
    case .success(let value):
      lastGoodValue = value
      settle(.current(value))
      if case .providerSwitch(let continuation) = completedOperation {
        continuation.resume(returning: value)
      }
    case .failure(let error):
      let failure = RefreshFailure(error)
      if let lastGoodValue {
        settle(.stale(lastGoodValue, failure: failure))
      } else {
        settle(.failed(failure))
      }
      if case .providerSwitch(let continuation) = completedOperation {
        continuation.resume(throwing: error)
      }
    }

    runNextOperationIfNeeded()
    if activeOperation == nil, pendingOperations.isEmpty {
      resumeIdleWaiters()
    }
  }

  private func settle(_ newState: RefreshState<Value>) {
    lastSettledState = newState
    publish(newState)
  }

  private func publish(_ newState: RefreshState<Value>) {
    state = newState
    for observer in observers.values {
      observer.yield(newState)
    }
  }

  private func removeObserver(id: UUID) {
    observers.removeValue(forKey: id)
  }

  private func resumeIdleWaiters() {
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
