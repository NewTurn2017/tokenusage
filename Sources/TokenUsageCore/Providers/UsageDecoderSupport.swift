import Foundation

public enum UsageDecodingError: Error, Equatable, Sendable {
    case invalidJSON
    case expectedObject(path: String)
    case expectedArray(path: String)
    case missingField(path: String)
    case invalidType(path: String)
    case invalidDate(path: String)
}

extension UsageDecodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The provider response was not valid JSON."
        case let .expectedObject(path):
            return "The provider response has an invalid object at \(path)."
        case let .expectedArray(path):
            return "The provider response has an invalid array at \(path)."
        case let .missingField(path):
            return "The provider response is missing \(path)."
        case let .invalidType(path):
            return "The provider response has an invalid value at \(path)."
        case let .invalidDate(path):
            return "The provider response has an invalid date at \(path)."
        }
    }
}

enum UsageDecoderSupport {
    static func rootObject(from data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw UsageDecodingError.invalidJSON
        }

        guard let object = value as? [String: Any] else {
            throw UsageDecodingError.expectedObject(path: "root")
        }
        return object
    }

    static func optionalObject(_ value: Any?, path: String) throws -> [String: Any]? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let object = value as? [String: Any] else {
            throw UsageDecodingError.expectedObject(path: path)
        }
        return object
    }

    static func optionalArray(_ value: Any?, path: String) throws -> [Any]? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let array = value as? [Any] else {
            throw UsageDecodingError.expectedArray(path: path)
        }
        return array
    }

    static func requiredObject(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value else {
            throw UsageDecodingError.missingField(path: path)
        }
        guard let object = value as? [String: Any] else {
            throw UsageDecodingError.expectedObject(path: path)
        }
        return object
    }

    static func requiredString(_ value: Any?, path: String) throws -> String {
        guard let value else {
            throw UsageDecodingError.missingField(path: path)
        }
        guard let string = value as? String else {
            throw UsageDecodingError.invalidType(path: path)
        }
        return string
    }

    static func optionalString(_ value: Any?, path: String) throws -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let string = value as? String else {
            throw UsageDecodingError.invalidType(path: path)
        }
        return string
    }

    static func requiredInteger(_ value: Any?, path: String) throws -> Int {
        guard let value else {
            throw UsageDecodingError.missingField(path: path)
        }
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else {
            throw UsageDecodingError.invalidType(path: path)
        }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded() == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max)
        else {
            throw UsageDecodingError.invalidType(path: path)
        }
        return Int(doubleValue)
    }

    static func optionalNumber(_ value: Any?, path: String) throws -> Double? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else {
            throw UsageDecodingError.invalidType(path: path)
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite else {
            throw UsageDecodingError.invalidType(path: path)
        }
        return doubleValue
    }

    static func optionalISO8601Date(_ value: Any?, path: String) throws -> Date? {
        guard let string = try optionalString(value, path: path) else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else {
            throw UsageDecodingError.invalidDate(path: path)
        }
        return date
    }

    static func normalizedWindow(
        usedPercent: Int,
        window: QuotaWindowKind,
        resetsAt: Date?
    ) -> (window: QuotaWindow, warning: UsageWarning?) {
        let remaining = min(100.0, max(0.0, 100.0 - Double(usedPercent)))
        let warning: UsageWarning? = (0...100).contains(usedPercent)
            ? nil
            : .providerUsedPercentOutOfRange(window: window, value: usedPercent)
        let quotaWindow = QuotaWindow(
            remainingPercent: remaining,
            resetsAt: resetsAt,
            windowDuration: window.duration
        )
        return (quotaWindow, warning)
    }
}
