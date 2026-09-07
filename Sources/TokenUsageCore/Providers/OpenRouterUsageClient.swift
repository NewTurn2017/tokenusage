import Foundation

public enum OpenRouterUsageClientError: Error, Equatable, Sendable {
    case keyUnavailable
    case unauthorized
    case timeout
    case networkFailure
    case malformedResponse
    case unexpectedHTTPStatus(Int)
}

extension OpenRouterUsageClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keyUnavailable:
            "OpenRouter API key is not configured."
        case .unauthorized:
            "OpenRouter authorization failed."
        case .timeout:
            "OpenRouter usage request timed out."
        case .networkFailure:
            "OpenRouter usage could not be reached."
        case .malformedResponse:
            "OpenRouter returned an invalid usage response."
        case let .unexpectedHTTPStatus(statusCode):
            "OpenRouter usage returned HTTP status \(statusCode)."
        }
    }
}

public struct OpenRouterUsageSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let usage: Double
    public let totalCredits: Double
    public let totalUsage: Double
    public let limit: Double?
    public let remaining: Double
    public let isFreeTier: Bool?
    public let rateLimit: String?

    public init(
        capturedAt: Date,
        usage: Double,
        totalCredits: Double,
        totalUsage: Double,
        limit: Double?,
        isFreeTier: Bool?,
        rateLimit: String?
    ) {
        self.capturedAt = capturedAt
        self.usage = usage
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.limit = limit
        remaining = limit.map { $0 - usage } ?? (totalCredits - totalUsage)
        self.isFreeTier = isFreeTier
        self.rateLimit = rateLimit
    }
}

public struct OpenRouterUsageClient: Sendable {
    public static let keyEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    public static let creditsEndpoint = URL(string: "https://openrouter.ai/api/v1/credits")!

    private let environment: [String: String]
    private let keyFileURL: URL
    private let readKeyFile: @Sendable (URL) throws -> Data
    private let session: any URLSessionProtocol
    private let capturedAt: @Sendable () -> Date

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyFileURL: URL? = nil,
        fileReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        session: any URLSessionProtocol = URLSession.shared,
        capturedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.keyFileURL = keyFileURL ?? Self.defaultKeyFileURL(environment: environment)
        readKeyFile = fileReader
        self.session = session
        self.capturedAt = capturedAt
    }

    public func usage() async throws -> OpenRouterUsageSnapshot {
        guard let apiKey = readAPIKey() else {
            throw OpenRouterUsageClientError.keyUnavailable
        }

        async let keyResponse: KeyResponse = request(
            endpoint: Self.keyEndpoint,
            apiKey: apiKey
        )
        async let creditsResponse: CreditsResponse = request(
            endpoint: Self.creditsEndpoint,
            apiKey: apiKey
        )
        let (key, credits) = try await (keyResponse, creditsResponse)

        return OpenRouterUsageSnapshot(
            capturedAt: capturedAt(),
            usage: key.data.usage,
            totalCredits: credits.data.totalCredits,
            totalUsage: credits.data.totalUsage,
            limit: key.data.limit,
            isFreeTier: key.data.isFreeTier,
            rateLimit: key.data.rateLimit.map { "\($0.requests)/\($0.interval)" }
        )
    }

    private func readAPIKey() -> String? {
        if let environmentKey = environment["OPENROUTER_API_KEY"] {
            let trimmedKey = environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                return trimmedKey
            }
        }

        guard let fileData = try? readKeyFile(keyFileURL),
              let fileKey = String(data: fileData, encoding: .utf8)
        else {
            return nil
        }
        let trimmedKey = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? nil : trimmedKey
    }

    private func request<Response: Decodable>(
        endpoint: URL,
        apiKey: String
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw OpenRouterUsageClientError.timeout
        } catch {
            throw OpenRouterUsageClientError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterUsageClientError.malformedResponse
        }
        if httpResponse.statusCode == 401 {
            throw OpenRouterUsageClientError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenRouterUsageClientError.unexpectedHTTPStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OpenRouterUsageClientError.malformedResponse
        }
    }

    private static func defaultKeyFileURL(environment: [String: String]) -> URL {
        let homeURL = environment["HOME"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/openrouter/key", isDirectory: false)
    }
}

private struct KeyResponse: Decodable {
    let data: KeyData
}

private struct KeyData: Decodable {
    let limit: Double?
    let usage: Double
    let isFreeTier: Bool?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case limit
        case usage
        case isFreeTier = "is_free_tier"
        case rateLimit = "rate_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decodeIfPresent(Double.self, forKey: .limit)
        usage = try container.decode(Double.self, forKey: .usage)
        isFreeTier = try container.decodeIfPresent(Bool.self, forKey: .isFreeTier)
        // rate_limit is documented as deprecated, so its shape must never fail the whole read.
        rateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
    }
}

private struct RateLimit: Decodable {
    let requests: Int
    let interval: String
}

private struct CreditsResponse: Decodable {
    let data: CreditsData
}

private struct CreditsData: Decodable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}
