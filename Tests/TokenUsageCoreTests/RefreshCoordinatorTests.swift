import XCTest

@testable import TokenUsageCore

final class RefreshCoordinatorTests: XCTestCase {
  func testStartRefreshesImmediatelyAndEveryExactFiveMinutes() async throws {
    let clock = ManualRefreshClock()
    let refresh = ControlledOperation<Int>()
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = StreamProbe(await coordinator.stateChanges())
    let refreshCalls = StreamProbe(refresh.invocations)
    let clockSleeps = StreamProbe(clock.sleeps)

    try await assertNext(states, equals: .idle)
    await coordinator.start()

    try await assertNext(states, equals: .refreshing(previous: nil))
    try await assertNext(refreshCalls, equals: 1)
    try await assertNext(clockSleeps, equals: .seconds(300))
    await refresh.succeed(invocation: 1, with: 10)
    try await assertNext(states, equals: .current(10))
    await coordinator.waitUntilIdle()
    let immediateInvocationCount = await refresh.invocationCount
    XCTAssertEqual(immediateInvocationCount, 1)

    await clock.advance(by: .seconds(299))
    let beforeIntervalInvocationCount = await refresh.invocationCount
    XCTAssertEqual(beforeIntervalInvocationCount, 1)

    await clock.advance(by: .seconds(1))
    try await assertNext(states, equals: .refreshing(previous: 10))
    try await assertNext(refreshCalls, equals: 2)
    let intervalInvocationCount = await refresh.invocationCount
    XCTAssertEqual(intervalInvocationCount, 2)
    await refresh.succeed(invocation: 2, with: 20)
    try await assertNext(states, equals: .current(20))
    await coordinator.waitUntilIdle()
    let totalInvocationCount = await refresh.invocationCount
    XCTAssertEqual(totalInvocationCount, 2)
    try await assertNext(clockSleeps, equals: .seconds(300))

    await coordinator.stop()
  }

  func testConcurrentTimerAndManualRequestsCoalesceToOnePendingRefresh() async throws {
    let clock = ManualRefreshClock()
    let refresh = ControlledOperation<Int>()
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = StreamProbe(await coordinator.stateChanges())
    let refreshCalls = StreamProbe(refresh.invocations)
    let clockSleeps = StreamProbe(clock.sleeps)

    try await assertNext(states, equals: .idle)
    await coordinator.start()
    try await assertNext(states, equals: .refreshing(previous: nil))
    try await assertNext(refreshCalls, equals: 1)
    try await assertNext(clockSleeps, equals: .seconds(300))

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask { await coordinator.requestRefresh() }
      }
      group.addTask { await coordinator.requestRefresh() }
      group.addTask { try? await clock.advanceNextSleep() }
    }
    // The next sleep starts only after the timer request has reached the coordinator.
    try await assertNext(clockSleeps, equals: .seconds(300))

    await refresh.succeed(invocation: 1, with: 10)
    try await assertNext(states, equals: .current(10))
    try await assertNext(states, equals: .refreshing(previous: 10))
    try await assertNext(refreshCalls, equals: 2)
    await refresh.succeed(invocation: 2, with: 20)
    try await assertNext(states, equals: .current(20))
    await coordinator.waitUntilIdle()

    let invocationCount = await refresh.invocationCount
    XCTAssertEqual(invocationCount, 2)
    await coordinator.stop()
  }

  func testSwitchOperationsUseTheRefreshGate() async throws {
    let clock = ManualRefreshClock()
    let activity = OperationActivity()
    let refresh = ControlledOperation<Int>(activity: activity)
    let providerSwitch = ControlledOperation<Int>(activity: activity)
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = StreamProbe(await coordinator.stateChanges())
    let refreshCalls = StreamProbe(refresh.invocations)
    let switchCalls = StreamProbe(providerSwitch.invocations)

    try await assertNext(states, equals: .idle)
    await coordinator.start()
    try await assertNext(states, equals: .refreshing(previous: nil))
    try await assertNext(refreshCalls, equals: 1)

    let switchResult = Task {
      try await coordinator.performSwitch {
        try await providerSwitch.run()
      }
    }

    await refresh.succeed(invocation: 1, with: 10)
    try await assertNext(states, equals: .current(10))
    try await assertNext(states, equals: .switching(previous: 10))
    try await assertNext(switchCalls, equals: 1)

    // A refresh accepted while switching must remain behind the same operation gate.
    await coordinator.requestRefresh()
    await providerSwitch.succeed(invocation: 1, with: 30)

    let switchedValue = try await switchResult.value
    XCTAssertEqual(switchedValue, 30)
    try await assertNext(states, equals: .current(30))
    try await assertNext(states, equals: .refreshing(previous: 30))
    try await assertNext(refreshCalls, equals: 2)
    await refresh.succeed(invocation: 2, with: 40)
    try await assertNext(states, equals: .current(40))
    await coordinator.waitUntilIdle()
    let maximumConcurrentOperations = await activity.maximumConcurrentOperations
    XCTAssertEqual(maximumConcurrentOperations, 1)

    await coordinator.stop()
  }

  func testFailedRefreshPublishesLastGoodValueAsStale() async throws {
    let clock = ManualRefreshClock()
    let refresh = ControlledOperation<Int>()
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = StreamProbe(await coordinator.stateChanges())
    let refreshCalls = StreamProbe(refresh.invocations)

    try await assertNext(states, equals: .idle)
    await coordinator.start()
    try await assertNext(states, equals: .refreshing(previous: nil))
    try await assertNext(refreshCalls, equals: 1)
    await refresh.succeed(invocation: 1, with: 42)
    try await assertNext(states, equals: .current(42))
    await coordinator.waitUntilIdle()

    await coordinator.requestRefresh()
    try await assertNext(states, equals: .refreshing(previous: 42))
    try await assertNext(refreshCalls, equals: 2)
    await refresh.fail(invocation: 2, with: TestFailure.refresh)

    try await assertNext(
      states,
      equals: .stale(42, failure: RefreshFailure(TestFailure.refresh))
    )
    await coordinator.waitUntilIdle()
    let state = await coordinator.currentState()
    XCTAssertEqual(state, .stale(42, failure: RefreshFailure(TestFailure.refresh)))

    await coordinator.stop()
    let stoppedState = await coordinator.currentState()
    XCTAssertEqual(stoppedState, .stale(42, failure: RefreshFailure(TestFailure.refresh)))
  }

  func testSlowObserverKeepsOnlyNewestStateAcrossRepeatedRefreshes() async throws {
    let clock = ManualRefreshClock()
    let refresh = ControlledOperation<Int>()
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = await coordinator.stateChanges()
    let refreshCalls = StreamProbe(refresh.invocations)

    await coordinator.start()
    for invocation in 1...30 {
      try await assertNext(refreshCalls, equals: invocation)
      await refresh.succeed(invocation: invocation, with: invocation)
      await coordinator.waitUntilIdle()
      if invocation < 30 {
        await coordinator.requestRefresh()
      }
    }

    var iterator = states.makeAsyncIterator()
    let newestState = await iterator.next()
    XCTAssertEqual(newestState, .current(30))

    await coordinator.stop()
  }

  func testStopFinishesObserverStreams() async throws {
    let clock = ManualRefreshClock()
    let refresh = ControlledOperation<Int>()
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = StreamProbe(await coordinator.stateChanges())
    let refreshCalls = StreamProbe(refresh.invocations)
    let streamFinished = expectation(description: "state stream finished")

    try await assertNext(states, equals: .idle)
    await coordinator.start()
    try await assertNext(states, equals: .refreshing(previous: nil))
    try await assertNext(refreshCalls, equals: 1)

    let termination = Task {
      while await states.next() != nil {}
      streamFinished.fulfill()
    }
    await coordinator.stop()

    await fulfillment(of: [streamFinished], timeout: 1)
    termination.cancel()
  }

  func testStopCancelsSchedulerAndOwnedProviderTask() async throws {
    let clock = ManualRefreshClock()
    let refresh = ControlledOperation<Int>()
    let coordinator = RefreshCoordinator<Int>(clock: clock) {
      try await refresh.run()
    }
    let states = StreamProbe(await coordinator.stateChanges())
    let refreshCalls = StreamProbe(refresh.invocations)
    let clockSleeps = StreamProbe(clock.sleeps)
    let refreshCancellations = StreamProbe(refresh.cancellations)
    let sleepCancellations = StreamProbe(clock.cancellations)

    try await assertNext(states, equals: .idle)
    await coordinator.start()
    try await assertNext(states, equals: .refreshing(previous: nil))
    try await assertNext(refreshCalls, equals: 1)
    try await assertNext(clockSleeps, equals: .seconds(300))

    await coordinator.stop()

    try await assertNext(refreshCancellations, equals: 1)
    _ = try await next(sleepCancellations)
    await coordinator.waitUntilIdle()
    let invocationCount = await refresh.invocationCount
    XCTAssertEqual(invocationCount, 1)
  }
}

private enum TestFailure: Error {
  case refresh
}

private enum AsyncTestError: Error {
  case streamEnded
  case noPendingSleep
}

private func assertNext<Element: Equatable & Sendable>(
  _ probe: StreamProbe<Element>,
  equals expected: Element,
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  let actual = try await next(probe)
  XCTAssertEqual(actual, expected, file: file, line: line)
}

private func next<Element: Sendable>(
  _ probe: StreamProbe<Element>
) async throws -> Element {
  guard let element = await probe.next() else {
    throw AsyncTestError.streamEnded
  }
  return element
}

private final class StreamProbe<Element: Sendable>: Sendable {
  private let inbox = EventInbox<Element>()

  init(_ stream: AsyncStream<Element>) {
    let inbox = self.inbox
    Task {
      for await element in stream {
        await inbox.send(element)
      }
      await inbox.finish()
    }
  }

  func next() async -> Element? {
    await inbox.next()
  }
}

private actor EventInbox<Element: Sendable> {
  private var buffered: [Element] = []
  private var waiters: [UUID: CheckedContinuation<Element?, Never>] = [:]
  private var finished = false

  func send(_ element: Element) {
    if let waiter = waiters.first {
      waiters.removeValue(forKey: waiter.key)
      waiter.value.resume(returning: element)
    } else {
      buffered.append(element)
    }
  }

  func finish() {
    finished = true
    let pending = waiters.values
    waiters.removeAll()
    for waiter in pending {
      waiter.resume(returning: nil)
    }
  }

  func next() async -> Element? {
    if !buffered.isEmpty {
      return buffered.removeFirst()
    }
    if finished {
      return nil
    }

    let id = UUID()
    return await withTaskCancellationHandler {
      if Task.isCancelled {
        return nil
      }
      return await withCheckedContinuation { continuation in
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  private func cancelWaiter(id: UUID) {
    waiters.removeValue(forKey: id)?.resume(returning: nil)
  }
}

private actor ManualRefreshClock: RefreshClock {
  nonisolated let sleeps: AsyncStream<Duration>
  nonisolated let cancellations: AsyncStream<UUID>

  private let sleepEvents: AsyncStream<Duration>.Continuation
  private let cancellationEvents: AsyncStream<UUID>.Continuation
  private var now: Duration = .zero
  private var pendingSleeps: [(UUID, deadline: Duration, CheckedContinuation<Void, any Error>)] = []

  init() {
    let sleeps = AsyncStream<Duration>.makeStream()
    self.sleeps = sleeps.stream
    sleepEvents = sleeps.continuation

    let cancellations = AsyncStream<UUID>.makeStream()
    self.cancellations = cancellations.stream
    cancellationEvents = cancellations.continuation
  }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    let deadline = now + duration
    sleepEvents.yield(duration)

    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        pendingSleeps.append((id, deadline, continuation))
      }
    } onCancel: {
      Task { await self.cancelSleep(id: id) }
    }
  }

  func advance(by duration: Duration) {
    guard duration >= .zero else {
      return
    }

    now += duration
    let dueSleeps = pendingSleeps.filter { $0.deadline <= now }
    pendingSleeps.removeAll { $0.deadline <= now }
    for (_, _, continuation) in dueSleeps {
      continuation.resume()
    }
  }

  func advanceNextSleep() throws {
    guard let nextSleep = pendingSleeps.min(by: { $0.deadline < $1.deadline }) else {
      throw AsyncTestError.noPendingSleep
    }
    advance(by: nextSleep.deadline - now)
  }

  private func cancelSleep(id: UUID) {
    guard let index = pendingSleeps.firstIndex(where: { $0.0 == id }) else {
      return
    }
    let (_, _, continuation) = pendingSleeps.remove(at: index)
    cancellationEvents.yield(id)
    continuation.resume(throwing: CancellationError())
  }
}

private actor OperationActivity {
  private var activeOperations = 0
  private(set) var maximumConcurrentOperations = 0

  func started() {
    activeOperations += 1
    maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
  }

  func finished() {
    activeOperations -= 1
  }
}

private actor ControlledOperation<Value: Sendable> {
  nonisolated let invocations: AsyncStream<Int>
  nonisolated let cancellations: AsyncStream<Int>

  private let invocationEvents: AsyncStream<Int>.Continuation
  private let cancellationEvents: AsyncStream<Int>.Continuation
  private let activity: OperationActivity?
  private var continuations: [Int: CheckedContinuation<Value, any Error>] = [:]
  private(set) var invocationCount = 0

  init(activity: OperationActivity? = nil) {
    self.activity = activity

    let invocations = AsyncStream<Int>.makeStream()
    self.invocations = invocations.stream
    invocationEvents = invocations.continuation

    let cancellations = AsyncStream<Int>.makeStream()
    self.cancellations = cancellations.stream
    cancellationEvents = cancellations.continuation
  }

  func run() async throws -> Value {
    invocationCount += 1
    let invocation = invocationCount
    await activity?.started()
    invocationEvents.yield(invocation)

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        continuations[invocation] = continuation
      }
    } onCancel: {
      Task { await self.cancel(invocation: invocation) }
    }
  }

  func succeed(invocation: Int, with value: Value) async {
    guard let continuation = continuations.removeValue(forKey: invocation) else {
      return
    }
    await activity?.finished()
    continuation.resume(returning: value)
  }

  func fail(invocation: Int, with error: any Error) async {
    guard let continuation = continuations.removeValue(forKey: invocation) else {
      return
    }
    await activity?.finished()
    continuation.resume(throwing: error)
  }

  private func cancel(invocation: Int) async {
    guard let continuation = continuations.removeValue(forKey: invocation) else {
      return
    }
    await activity?.finished()
    cancellationEvents.yield(invocation)
    continuation.resume(throwing: CancellationError())
  }
}
