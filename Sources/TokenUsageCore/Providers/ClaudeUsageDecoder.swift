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

        return UsageSnapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHourResult.window,
            weekly: weeklyResult.window,
            fableWeekly: fableResult.window,
            warnings: [fiveHourResult.warning, weeklyResult.warning, fableResult.warning].compactMap { $0 }
        )
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
