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

    func testClaudeResetCreditsSumRemainingGrantsAndKeepTheSoonestDeadline() throws {
        let snapshot = try ClaudeUsageDecoder().decode(
            jsonData(
                """
                {"cedar_ember":{"eligible":true,"grants":[
                  {"id":"a","resets_total":1,"resets_left":1,"ends_at":"2026-10-22T16:00:00+00:00"},
                  {"id":"b","resets_total":2,"resets_left":2,"ends_at":"2026-10-01T00:00:00Z"},
                  {"id":"c","resets_total":1,"resets_left":0,"ends_at":"2026-09-23T00:00:00Z"}
                ]}}
                """
            )
        )

        XCTAssertEqual(snapshot.rateLimitResetCreditsAvailableCount, 3)
        XCTAssertEqual(snapshot.rateLimitResetCreditsExpireAt, Date(timeIntervalSince1970: 1_790_812_800))
    }

    func testClaudeResetCreditsAreHiddenWhenIneligibleMissingOrMalformed() throws {
        let bodies = [
            #"{"five_hour":{"utilization":10,"resets_at":null}}"#,
            #"{"five_hour":{"utilization":10,"resets_at":null},"cedar_ember":null}"#,
            #"{"five_hour":{"utilization":10,"resets_at":null},"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#,
            #"{"five_hour":{"utilization":10,"resets_at":null},"cedar_ember":{"eligible":true,"grants":[{"resets_left":"1"}]}}"#,
            #"{"five_hour":{"utilization":10,"resets_at":null},"cedar_ember":"unexpected"}"#,
        ]

        for body in bodies {
            let snapshot = try ClaudeUsageDecoder().decode(jsonData(body))
            XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90, body)
            XCTAssertNil(snapshot.rateLimitResetCreditsAvailableCount, body)
            XCTAssertNil(snapshot.rateLimitResetCreditsExpireAt, body)
        }
    }

    func testClaudeEligibleAccountWithoutGrantsHasZeroResetCredits() throws {
        let snapshot = try ClaudeUsageDecoder().decode(
            jsonData(#"{"cedar_ember":{"eligible":true,"grants":[]}}"#)
        )

        XCTAssertEqual(snapshot.rateLimitResetCreditsAvailableCount, 0)
        XCTAssertNil(snapshot.rateLimitResetCreditsExpireAt)
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

    func testCodexAdditionalCreditsAreIndependentOfWeeklyQuotaAndResetCoupons() throws {
        let snapshot = try CodexUsageDecoder().decode(jsonData("""
        {"result":{
          "rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080},
            "credits":{"hasCredits":true,"unlimited":false,"balance":"52771.1155980000"}},
          "rateLimitResetCredits":{"availableCount":0}
        }}
        """))

        XCTAssertEqual(snapshot.codexCredits, CodexCredits(
            hasCredits: true, unlimited: false, balance: 52771.115598
        ))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 0)
        XCTAssertEqual(snapshot.rateLimitResetCreditsAvailableCount, 0)
    }

    func testCodexAdditionalCreditsPreserveZeroUnlimitedHiddenAndMissingBalances() throws {
        for (payload, expected) in [
            (#"{"hasCredits":false,"unlimited":false,"balance":"0"}"#,
             CodexCredits(hasCredits: false, unlimited: false, balance: 0)),
            (#"{"hasCredits":false,"unlimited":true,"balance":null}"#,
             CodexCredits(hasCredits: false, unlimited: true)),
            (#"{"hasCredits":true,"unlimited":false,"balance":null}"#,
             CodexCredits(hasCredits: true, unlimited: false)),
        ] {
            let snapshot = try CodexUsageDecoder().decode(jsonData(
                #"{"result":{"rateLimits":{"credits":\#(payload)}}}"#
            ))
            XCTAssertEqual(snapshot.codexCredits, expected)
            XCTAssertNil(snapshot.weekly)
        }
        for payload in [#"{"result":{}}"#, #"{"result":{"rateLimits":{"credits":null}}}"#] {
            XCTAssertNil(try CodexUsageDecoder().decode(jsonData(payload)).codexCredits)
        }
    }

    func testCodexAdditionalCreditsPreferDirectBalanceThenOnlyCodexMapBucket() throws {
        let map = """
        "rateLimitsByLimitId":{
          "other":{"credits":{"hasCredits":true,"unlimited":false,"balance":"999"}},
          "codex":{"credits":{"hasCredits":true,"unlimited":false,"balance":"42.5"}}
        }
        """
        let mapped = try CodexUsageDecoder().decode(jsonData(
            #"{"result":{"rateLimits":{"credits":null},\#(map)}}"#
        ))
        let direct = try CodexUsageDecoder().decode(jsonData(
            #"{"result":{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}},\#(map)}}"#
        ))
        let unrelated = try CodexUsageDecoder().decode(jsonData("""
        {"result":{"rateLimitsByLimitId":{
          "other":{"credits":{"hasCredits":true,"unlimited":false,"balance":"999"}}
        }}}
        """))
        XCTAssertEqual(mapped.codexCredits?.balance, 42.5)
        XCTAssertEqual(direct.codexCredits?.balance, 0)
        XCTAssertNil(unrelated.codexCredits)
    }

    func testCodexRejectsMalformedAdditionalCreditBalances() {
        for balance in [#""NaN""#, #""inf""#, #""-1""#, #""bad""#, "12", "true"] {
            XCTAssertThrowsError(try CodexUsageDecoder().decode(jsonData(
                #"{"result":{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":\#(balance)}}}}"#
            )))
        }
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
