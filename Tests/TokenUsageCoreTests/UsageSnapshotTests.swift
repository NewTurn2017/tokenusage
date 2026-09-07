import Foundation
import XCTest
@testable import TokenUsageCore

final class UsageSnapshotTests: XCTestCase {
    func testClaudeRemainingPercentageBoundariesAreClampedAndWarnWhenOutOfRange() throws {
        let cases: [(used: Int, remaining: Double, warning: UsageWarning?)] = [
            (-1, 100, .providerUsedPercentOutOfRange(window: .fiveHour, value: -1)),
            (0, 100, nil),
            (16, 84, nil),
            (100, 0, nil),
            (101, 0, .providerUsedPercentOutOfRange(window: .fiveHour, value: 101)),
        ]

        for testCase in cases {
            let data = jsonData(
                """
                {"five_hour":{"utilization":\(testCase.used),"resets_at":"2026-08-03T12:34:56Z"}}
                """
            )
            let snapshot = try ClaudeUsageDecoder().decode(
                data,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            XCTAssertEqual(snapshot.fiveHour?.remainingPercent, testCase.remaining)
            XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_785_760_496))
            XCTAssertEqual(snapshot.warnings, testCase.warning.map { [$0] } ?? [])
        }
    }

    func testClaudeMissingBucketRemainsAbsentAndNullResetIsAllowed() throws {
        let snapshot = try ClaudeUsageDecoder().decode(
            jsonData(#"{"seven_day":{"utilization":16,"resets_at":null}}"#),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(
            snapshot.weekly,
            QuotaWindow(
                remainingPercent: 84,
                resetsAt: nil,
                windowDuration: QuotaWindowKind.weekly.duration
            )
        )
        XCTAssertNil(snapshot.fableWeekly)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testClaudeRejectsMalformedUtilizationTypeAndResetDate() {
        let malformedType = jsonData(#"{"five_hour":{"utilization":"16","resets_at":null}}"#)
        let malformedDate = jsonData(#"{"five_hour":{"utilization":16,"resets_at":"next Tuesday"}}"#)

        XCTAssertThrowsError(try ClaudeUsageDecoder().decode(malformedType))
        XCTAssertThrowsError(try ClaudeUsageDecoder().decode(malformedDate))
    }

    func testClaudeSelectsOnlyWeeklyScopedFableLimit() throws {
        let snapshot = try ClaudeUsageDecoder().decode(
            jsonData(
                """
                {"limits":[
                  {"kind":"weekly_scoped","scope":{"model":{"display_name":"Sonnet"}},"percent":4,"resets_at":"2026-08-10T00:00:00Z"},
                  {"kind":"daily_scoped","scope":{"model":{"display_name":"Fable"}},"percent":90,"resets_at":"2026-08-04T00:00:00Z"},
                  {"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":16,"resets_at":"2026-08-10T00:00:00.500Z"}
                ]}
                """
            ),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.fableWeekly?.remainingPercent, 84)
        XCTAssertEqual(snapshot.fableWeekly?.resetsAt, Date(timeIntervalSince1970: 1_786_320_000.5))
    }

    func testCodexResetCouponCountUsesAuthoritativeAvailableCount() throws {
        let snapshot = try CodexUsageDecoder().decode(
            jsonData(
                """
                {"result":{
                  "rateLimits":{"primary":null,"secondary":null},
                  "rateLimitResetCredits":{
                    "availableCount":4,
                    "credits":[{"id":"only-visible-detail"}]
                  }
                }}
                """
            )
        )

        XCTAssertEqual(snapshot.rateLimitResetCreditsAvailableCount, 4)
    }

    func testCodexResetCouponCountPreservesZeroAndMissing() throws {
        let zero = try CodexUsageDecoder().decode(
            jsonData(
                """
                {"result":{
                  "rateLimits":{"primary":null,"secondary":null},
                  "rateLimitResetCredits":{"availableCount":0}
                }}
                """
            )
        )
        let missing = try CodexUsageDecoder().decode(
            jsonData(#"{"result":{"rateLimits":{"primary":null,"secondary":null}}}"#)
        )
        let null = try CodexUsageDecoder().decode(
            jsonData(
                #"{"result":{"rateLimits":{"primary":null,"secondary":null},"rateLimitResetCredits":null}}"#
            )
        )

        XCTAssertEqual(zero.rateLimitResetCreditsAvailableCount, 0)
        XCTAssertNil(missing.rateLimitResetCreditsAvailableCount)
        XCTAssertNil(null.rateLimitResetCreditsAvailableCount)
    }

    func testCodexSelectsWeeklyWindowFromPrimary() throws {
        let snapshot = try CodexUsageDecoder().decode(
            jsonData(
                """
                {"id":2,"result":{"rateLimits":{
                  "primary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1776038400},
                  "secondary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1775500000}
                }}}
                """
            ),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_003)
        )

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly, QuotaWindow(
            remainingPercent: 84,
            resetsAt: Date(timeIntervalSince1970: 1_776_038_400),
            windowDuration: QuotaWindowKind.weekly.duration
        ))
        XCTAssertNil(snapshot.fableWeekly)
    }

    func testCodexSelectsWeeklyWindowFromSecondary() throws {
        let snapshot = try CodexUsageDecoder().decode(
            jsonData(
                """
                {"result":{"rateLimits":{
                  "primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1775500000},
                  "secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":null}
                }}}
                """
            )
        )

        XCTAssertEqual(
            snapshot.weekly,
            QuotaWindow(
                remainingPercent: 0,
                resetsAt: nil,
                windowDuration: QuotaWindowKind.weekly.duration
            )
        )
    }

    func testCodexSelectsWeeklyWindowFromRateLimitMapWithoutFabricatingMissingBuckets() throws {
        let mapped = try CodexUsageDecoder().decode(
            jsonData(
                """
                {"result":{
                  "rateLimits":{"primary":null,"secondary":null},
                  "rateLimitsByLimitId":{
                    "other":{"primary":{"usedPercent":70,"windowDurationMins":60,"resetsAt":1775500000}},
                    "codex":{"secondary":{"usedPercent":101,"windowDurationMins":10080,"resetsAt":1776038400}}
                  }
                }}
                """
            )
        )
        let missing = try CodexUsageDecoder().decode(
            jsonData(
                """
                {"result":{"rateLimits":{"primary":{
                  "usedPercent":16,"windowDurationMins":300,"resetsAt":1775500000
                }}}}
                """
            )
        )

        XCTAssertEqual(mapped.weekly?.remainingPercent, 0)
        XCTAssertEqual(mapped.warnings, [
            .providerUsedPercentOutOfRange(window: .weekly, value: 101),
        ])
        XCTAssertNil(missing.fiveHour)
        XCTAssertNil(missing.weekly)
        XCTAssertNil(missing.fableWeekly)
    }

    func testCodexRejectsMalformedUsedTypeAndResetTimestamp() {
        let malformedType = jsonData(
            #"{"result":{"rateLimits":{"primary":{"usedPercent":"16","windowDurationMins":10080,"resetsAt":null}}}}"#
        )
        let malformedReset = jsonData(
            #"{"result":{"rateLimits":{"primary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":"tomorrow"}}}}"#
        )

        XCTAssertThrowsError(try CodexUsageDecoder().decode(malformedType))
        XCTAssertThrowsError(try CodexUsageDecoder().decode(malformedReset))
    }

    func testRefreshFailureRetainsLastGoodSnapshotAsStaleOrIsUnavailableWithoutHistory() {
        let lastGood = UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_004),
            weekly: QuotaWindow(remainingPercent: 84, resetsAt: nil)
        )

        let stale = UsageState.refreshFailed(message: "connection lost", previous: .fresh(lastGood))
        let stillStale = UsageState.refreshFailed(message: "still offline", previous: stale)
        let unavailable = UsageState.refreshFailed(message: "not signed in", previous: nil)

        XCTAssertEqual(stale, .stale(lastGood: lastGood, message: "connection lost"))
        XCTAssertEqual(stillStale, .stale(lastGood: lastGood, message: "still offline"))
        XCTAssertEqual(unavailable, .unavailable(message: "not signed in"))
    }

    private func jsonData(_ json: String) -> Data {
        Data(json.utf8)
    }
}
