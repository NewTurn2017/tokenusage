import XCTest
@testable import TokenUsageCore

final class QuotaPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func window(
        remaining: Double,
        resetsIn: TimeInterval?,
        duration: TimeInterval? = 7 * 24 * 60 * 60
    ) -> QuotaWindow {
        QuotaWindow(
            remainingPercent: remaining,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            windowDuration: duration
        )
    }

    func testHalfwayThroughTheWeekWithHalfLeftIsOnTrack() throws {
        let quota = window(remaining: 50, resetsIn: week / 2)

        XCTAssertEqual(try XCTUnwrap(quota.expectedRemainingPercent(now: now)), 50, accuracy: 0.001)
        XCTAssertEqual(quota.pace(now: now), .onTrack)
    }

    func testMostOfTheWeekLeftButLittleQuotaIsOverspending() {
        let quota = window(remaining: 20, resetsIn: week * 0.9)

        XCTAssertEqual(quota.pace(now: now), .overspending)
    }

    func testLittleOfTheWeekLeftWithPlentyOfQuotaIsComfortable() {
        let quota = window(remaining: 80, resetsIn: week * 0.1)

        XCTAssertEqual(quota.pace(now: now), .comfortable)
    }

    func testZeroRemainingIsExhaustedEvenWithoutAReset() {
        XCTAssertEqual(window(remaining: 0, resetsIn: week / 2).pace(now: now), .exhausted)
        XCTAssertEqual(window(remaining: 0, resetsIn: nil).pace(now: now), .exhausted)
    }

    func testExactlyAtToleranceCountsAsFastOrSlowNotOnTrack() {
        let tolerance = QuotaWindow.paceTolerancePercentagePoints
        let expected = 50.0

        let fast = window(remaining: expected - tolerance, resetsIn: week / 2)
        let slow = window(remaining: expected + tolerance, resetsIn: week / 2)
        let inside = window(remaining: expected - tolerance + 0.5, resetsIn: week / 2)

        XCTAssertEqual(fast.pace(now: now), .overspending)
        XCTAssertEqual(slow.pace(now: now), .comfortable)
        XCTAssertEqual(inside.pace(now: now), .onTrack)
    }

    func testMissingResetOrDurationCannotBeJudged() {
        XCTAssertEqual(window(remaining: 50, resetsIn: nil).pace(now: now), .unknown)
        XCTAssertEqual(
            window(remaining: 50, resetsIn: week / 2, duration: nil).pace(now: now),
            .unknown
        )
        XCTAssertNil(window(remaining: 50, resetsIn: nil).expectedRemainingPercent(now: now))
    }

    func testAlreadyElapsedWindowIsNotJudged() {
        let quota = window(remaining: 50, resetsIn: -60)

        XCTAssertNil(quota.expectedRemainingPercent(now: now))
        XCTAssertEqual(quota.pace(now: now), .unknown)
    }

    func testDecodedWindowsCarryTheDurationOfTheirKind() {
        XCTAssertEqual(QuotaWindowKind.fiveHour.duration, 5 * 60 * 60)
        XCTAssertEqual(QuotaWindowKind.weekly.duration, week)
        XCTAssertEqual(QuotaWindowKind.fableWeekly.duration, week)

        let decoded = UsageDecoderSupport.normalizedWindow(
            usedPercent: 40,
            window: .fiveHour,
            resetsAt: now
        )
        XCTAssertEqual(decoded.window.windowDuration, 5 * 60 * 60)
    }
}
