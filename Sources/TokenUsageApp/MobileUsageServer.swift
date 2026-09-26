import Darwin
import Foundation
import Network
import Security

/// One parsed HTTP/1.1 request line plus the only header the server reads.
struct MobileUsageRequest: Equatable, Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let authorization: String?

    /// Parses the request head once `\r\n\r\n` has arrived; nil when the head is incomplete or
    /// not HTTP. The body, if any, is ignored: every route is a GET.
    static func parse(_ data: Data) -> MobileUsageRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
              let components = URLComponents(string: String(parts[1])),
              parts[1].hasPrefix("/")
        else {
            return nil
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        let authorization = lines.dropFirst().first {
            $0.lowercased().hasPrefix("authorization:")
        }.map {
            String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces)
        }
        return MobileUsageRequest(
            method: String(parts[0]),
            path: components.path,
            query: query,
            authorization: authorization
        )
    }
}

struct MobileUsageResponse: Equatable, Sendable {
    let status: Int
    let contentType: String
    let body: Data

    static func text(_ status: Int, _ message: String) -> MobileUsageResponse {
        MobileUsageResponse(
            status: status,
            contentType: "text/plain; charset=utf-8",
            body: Data(message.utf8)
        )
    }

    func serialized() -> Data {
        let reason = [
            200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
            405: "Method Not Allowed", 500: "Internal Server Error",
        ][status] ?? "Error"
        // The key travels in the URL, so nothing may cache the page or leak it as a referrer.
        let head = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }
}

/// Routes a request to the phone page, the usage JSON, or the Scriptable widget source. Every
/// route requires the access key, as `?k=` or `Authorization: Bearer`.
struct MobileUsageRouter: Sendable {
    let accessKey: String
    let baseURL: URL
    let document: @Sendable () async -> Data?

    func response(for request: MobileUsageRequest) async -> MobileUsageResponse {
        guard request.method == "GET" else { return .text(405, "GET only") }
        guard isAuthorized(request) else { return .text(401, "unauthorized") }

        switch request.path {
        case "/":
            return MobileUsageResponse(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(MobileUsagePages.html.utf8)
            )
        case "/usage.json":
            guard let data = await document() else { return .text(500, "usage unavailable") }
            return MobileUsageResponse(
                status: 200,
                contentType: "application/json; charset=utf-8",
                body: data
            )
        case "/widget.js":
            return MobileUsageResponse(
                status: 200,
                contentType: "text/plain; charset=utf-8",
                body: Data(MobileUsagePages.widget(baseURL: baseURL, accessKey: accessKey).utf8)
            )
        default:
            return .text(404, "not found")
        }
    }

    private func isAuthorized(_ request: MobileUsageRequest) -> Bool {
        let bearer = request.authorization.flatMap {
            $0.hasPrefix("Bearer ") ? String($0.dropFirst("Bearer ".count)) : nil
        }
        guard let presented = request.query["k"] ?? bearer else { return false }
        return Self.constantTimeEquals(presented, accessKey)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

enum TailscaleAddress {
    /// Tailscale hands out IPv4 addresses from the CGNAT range 100.64.0.0/10.
    static func isTailscale(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// The machine's current tailnet IPv4 address, or nil while Tailscale is down.
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let text = String(cString: host)
            if isTailscale(text) { return text }
        }
        return nil
    }
}

enum MobileAccessKey {
    /// Reads the saved key, creating one on first use so the phone link survives relaunches.
    ///
    /// The key lives in an owner-only file rather than the Keychain: it guards nothing more than
    /// usage percentages, and a Keychain item would ask for permission again after every ad-hoc
    /// re-signed build, blocking the main actor until someone answers.
    static func loadOrCreate(fileURL: URL) throws -> String {
        if let data = try? Data(contentsOf: fileURL),
           let key = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           key.count >= 32 {
            return key
        }
        let key = generate()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(key.utf8).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return key
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system random generator failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A tiny HTTP server bound to one address, answering each connection with one response.
final class MobileUsageServer: @unchecked Sendable {
    private static let maximumRequestBytes = 16 * 1024
    private let queue = DispatchQueue(label: "local.tokenusage.mobile-server")
    private let listener: NWListener
    private let router: MobileUsageRouter

    init(host: String, port: UInt16, router: MobileUsageRouter) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.router = router
    }

    func start(onFailure: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed = state { onFailure() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = MobileUsageRequest.parse(buffer) {
                Task {
                    let response = await self.router.response(for: request)
                    self.send(response, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > Self.maximumRequestBytes {
                self.send(.text(400, "bad request"), on: connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: MobileUsageResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Keeps the server on the current tailnet address: starts it once Tailscale is up, moves it if
/// the address changes, and publishes the phone link to the popover.
@MainActor
final class MobileAccessController {
    static let defaultPort: UInt16 = 8787
    private static let recheckInterval: Duration = .seconds(60)

    private let model: AppViewModel
    private let port: UInt16
    private let keyFileURL: URL
    private var server: MobileUsageServer?
    private var boundHost: String?
    private var monitorTask: Task<Void, Never>?

    init(model: AppViewModel, port: UInt16, keyFileURL: URL) {
        self.model = model
        self.port = port
        self.keyFileURL = keyFileURL
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile()
                try? await Task.sleep(for: Self.recheckInterval)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        stopServer()
    }

    private func reconcile() {
        let host = TailscaleAddress.current()
        guard host != boundHost || (host != nil && server == nil) else { return }
        stopServer()
        guard let host else { return }

        do {
            let key = try MobileAccessKey.loadOrCreate(fileURL: keyFileURL)
            guard let baseURL = URL(string: "http://\(host):\(port)") else { return }
            let model = model
            let router = MobileUsageRouter(accessKey: key, baseURL: baseURL) {
                await MainActor.run { try? model.mobileUsageDocument().jsonData() }
            }
            let server = try MobileUsageServer(host: host, port: port, router: router)
            server.start { [weak self] in
                Task { @MainActor in self?.stopServer() }
            }
            self.server = server
            boundHost = host
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/"
            components?.queryItems = [URLQueryItem(name: "k", value: key)]
            model.setMobileLink(components?.url)
        } catch {
            stopServer()
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        boundHost = nil
        model.setMobileLink(nil)
    }
}
