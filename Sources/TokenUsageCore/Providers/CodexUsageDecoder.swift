import Foundation

public struct CodexUsageDecoder: Sendable {
    private static let weeklyWindowDurationMinutes = 10_080

    public init() {}

    public func decode(_ data: Data, capturedAt: Date = Date()) throws -> UsageSnapshot {
        let root = try UsageDecoderSupport.rootObject(from: data)
        guard let result = try UsageDecoderSupport.optionalObject(root["result"], path: "result") else {
            return UsageSnapshot(capturedAt: capturedAt)
        }
        let resetCreditCount = try decodeResetCreditCount(result["rateLimitResetCredits"])

        if let window = try decodeWeeklyWindow(in: result["rateLimits"], path: "result.rateLimits") {
            return UsageSnapshot(
                capturedAt: capturedAt,
                weekly: window.window,
                rateLimitResetCreditsAvailableCount: resetCreditCount,
                warnings: warningArray(window.warning)
            )
        }

        if let window = try decodeWeeklyWindowFromMap(
            result["rateLimitsByLimitId"],
            path: "result.rateLimitsByLimitId"
        ) {
            return UsageSnapshot(
                capturedAt: capturedAt,
                weekly: window.window,
                rateLimitResetCreditsAvailableCount: resetCreditCount,
                warnings: warningArray(window.warning)
            )
        }

        return UsageSnapshot(
            capturedAt: capturedAt,
            rateLimitResetCreditsAvailableCount: resetCreditCount
        )
    }

    private func decodeResetCreditCount(_ value: Any?) throws -> Int? {
        guard let summary = try UsageDecoderSupport.optionalObject(
            value,
            path: "result.rateLimitResetCredits"
        ) else {
            return nil
        }
        let count = try UsageDecoderSupport.requiredInteger(
            summary["availableCount"],
            path: "result.rateLimitResetCredits.availableCount"
        )
        guard count >= 0 else {
            throw UsageDecodingError.invalidType(
                path: "result.rateLimitResetCredits.availableCount"
            )
        }
        return count
    }

    private func decodeWeeklyWindow(
        in value: Any?,
        path: String
    ) throws -> (window: QuotaWindow, warning: UsageWarning?)? {
        guard let limits = try UsageDecoderSupport.optionalObject(value, path: path) else {
            return nil
        }

        for key in ["primary", "secondary"] {
            guard let bucket = try UsageDecoderSupport.optionalObject(
                limits[key],
                path: "\(path).\(key)"
            ) else {
                continue
            }
            if let result = try decodeCandidate(bucket, path: "\(path).\(key)") {
                return result
            }
        }
        return nil
    }

    private func decodeWeeklyWindowFromMap(
        _ value: Any?,
        path: String
    ) throws -> (window: QuotaWindow, warning: UsageWarning?)? {
        guard let map = try UsageDecoderSupport.optionalObject(value, path: path) else {
            return nil
        }

        let keys = map.keys.sorted {
            let lhsIsCodex = $0.caseInsensitiveCompare("codex") == .orderedSame
            let rhsIsCodex = $1.caseInsensitiveCompare("codex") == .orderedSame
            if lhsIsCodex != rhsIsCodex { return lhsIsCodex }
            return $0 < $1
        }

        for key in keys {
            guard let limits = try UsageDecoderSupport.optionalObject(
                map[key],
                path: "\(path).\(key)"
            ) else {
                continue
            }
            if let result = try decodeWeeklyWindow(in: limits, path: "\(path).\(key)") {
                return result
            }
        }
        return nil
    }

    private func decodeCandidate(
        _ bucket: [String: Any],
        path: String
    ) throws -> (window: QuotaWindow, warning: UsageWarning?)? {
        let usedPercent = try UsageDecoderSupport.requiredInteger(
            bucket["usedPercent"],
            path: "\(path).usedPercent"
        )
        let duration = try UsageDecoderSupport.requiredInteger(
            bucket["windowDurationMins"],
            path: "\(path).windowDurationMins"
        )
        let resetSeconds = try UsageDecoderSupport.optionalNumber(
            bucket["resetsAt"],
            path: "\(path).resetsAt"
        )
        guard duration == Self.weeklyWindowDurationMinutes else { return nil }

        let resetDate = resetSeconds.map(Date.init(timeIntervalSince1970:))
        return UsageDecoderSupport.normalizedWindow(
            usedPercent: usedPercent,
            window: .weekly,
            resetsAt: resetDate
        )
    }

    private func warningArray(_ warning: UsageWarning?) -> [UsageWarning] {
        warning.map { [$0] } ?? []
    }
}
