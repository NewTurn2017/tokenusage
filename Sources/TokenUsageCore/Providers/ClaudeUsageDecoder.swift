import Foundation

public struct ClaudeUsageDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data, capturedAt: Date = Date()) throws -> UsageSnapshot {
        let response = try UsageDecoderSupport.rootObject(from: data)

        let fiveHourResult = try decodeBucket(
            response["five_hour"],
            path: "five_hour",
            window: .fiveHour,
            usedKey: "utilization"
        )
        let weeklyResult = try decodeBucket(
            response["seven_day"],
            path: "seven_day",
            window: .weekly,
            usedKey: "utilization"
        )
        let fableResult = try decodeFableLimit(response["limits"])
        let resetCredits = decodeResetCredits(response["cedar_ember"])

        return UsageSnapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHourResult.window,
            weekly: weeklyResult.window,
            fableWeekly: fableResult.window,
            rateLimitResetCreditsAvailableCount: resetCredits?.count,
            rateLimitResetCreditsExpireAt: resetCredits?.expiresAt,
            warnings: [fiveHourResult.warning, weeklyResult.warning, fableResult.warning].compactMap { $0 }
        )
    }

    /// Reads the undocumented `cedar_ember` reset-credit block. Its shape is not a contract, so
    /// anything unexpected hides the credits instead of failing the whole usage read.
    private func decodeResetCredits(_ value: Any?) -> (count: Int, expiresAt: Date?)? {
        guard let block = value as? [String: Any],
              block["eligible"] as? Bool == true,
              let grants = block["grants"] as? [Any]
        else {
            return nil
        }

        var count = 0
        var expiresAt: Date?
        for (index, rawGrant) in grants.enumerated() {
            guard let grant = rawGrant as? [String: Any],
                  let left = try? UsageDecoderSupport.requiredInteger(
                      grant["resets_left"],
                      path: "cedar_ember.grants[\(index)].resets_left"
                  ),
                  left >= 0
            else {
                return nil
            }
            guard left > 0 else { continue }
            count += left
            if let endsAt = try? UsageDecoderSupport.optionalISO8601Date(
                grant["ends_at"],
                path: "cedar_ember.grants[\(index)].ends_at"
            ) {
                expiresAt = min(expiresAt ?? endsAt, endsAt)
            }
        }
        return (count, expiresAt)
    }

    private func decodeBucket(
        _ value: Any?,
        path: String,
        window: QuotaWindowKind,
        usedKey: String
    ) throws -> (window: QuotaWindow?, warning: UsageWarning?) {
        guard let bucket = try UsageDecoderSupport.optionalObject(value, path: path) else {
            return (nil, nil)
        }

        let usedPercent = try UsageDecoderSupport.requiredInteger(bucket[usedKey], path: "\(path).\(usedKey)")
        let resetsAt = try UsageDecoderSupport.optionalISO8601Date(
            bucket["resets_at"],
            path: "\(path).resets_at"
        )
        let result = UsageDecoderSupport.normalizedWindow(
            usedPercent: usedPercent,
            window: window,
            resetsAt: resetsAt
        )
        return (result.window, result.warning)
    }

    private func decodeFableLimit(_ value: Any?) throws -> (window: QuotaWindow?, warning: UsageWarning?) {
        guard let limits = try UsageDecoderSupport.optionalArray(value, path: "limits") else {
            return (nil, nil)
        }

        for (index, rawLimit) in limits.enumerated() {
            let path = "limits[\(index)]"
            guard let limit = rawLimit as? [String: Any] else {
                throw UsageDecodingError.expectedObject(path: path)
            }

            guard let rawKind = limit["kind"] else { continue }
            let kind = try UsageDecoderSupport.requiredString(rawKind, path: "\(path).kind")
            guard kind == "weekly_scoped" else { continue }

            guard let scope = try UsageDecoderSupport.optionalObject(limit["scope"], path: "\(path).scope"),
                  let model = try UsageDecoderSupport.optionalObject(scope["model"], path: "\(path).scope.model"),
                  let displayName = try UsageDecoderSupport.optionalString(
                      model["display_name"],
                      path: "\(path).scope.model.display_name"
                  ),
                  displayName.caseInsensitiveCompare("Fable") == .orderedSame
            else {
                continue
            }

            let usedPercent = try UsageDecoderSupport.requiredInteger(
                limit["percent"],
                path: "\(path).percent"
            )
            let resetsAt = try UsageDecoderSupport.optionalISO8601Date(
                limit["resets_at"],
                path: "\(path).resets_at"
            )
            let result = UsageDecoderSupport.normalizedWindow(
                usedPercent: usedPercent,
                window: .fableWeekly,
                resetsAt: resetsAt
            )
            return (result.window, result.warning)
        }

        return (nil, nil)
    }
}
