import XCTest
@testable import CodeIslandCore

final class TokenRateTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func perMessage(_ tokens: Int, at offset: TimeInterval, id: String? = nil) -> TokenSample {
        TokenSample(timestamp: now.addingTimeInterval(offset), outputTokens: tokens, isCumulative: false, messageId: id)
    }

    private func cumulative(_ total: Int, at offset: TimeInterval) -> TokenSample {
        TokenSample(timestamp: now.addingTimeInterval(offset), outputTokens: total, isCumulative: true)
    }

    // MARK: - Per-message path (Claude)

    func testPerMessageSamplesAccumulate() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(40, at: -3, id: "a"))
        tracker.append(perMessage(60, at: -2, id: "b"))

        // 100 tokens over the 3s since the oldest sample.
        XCTAssertEqual(tracker.rate(now: now)!, 100.0 / 3.0, accuracy: 0.001)
    }

    func testPerMessageDedupesRepeatedMessageId() {
        var tracker = TokenRateTracker()
        // Tool-use continuation lines repeat id and usage.
        tracker.append(perMessage(40, at: -3, id: "a"))
        tracker.append(perMessage(40, at: -3, id: "a"))
        tracker.append(perMessage(60, at: -2, id: "b"))

        // 100 counted, not 140.
        XCTAssertEqual(tracker.rate(now: now)!, 100.0 / 3.0, accuracy: 0.001)
    }

    func testPerMessageWithoutIdNeverDedupes() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(40, at: -3))
        tracker.append(perMessage(40, at: -2))

        // 80 tokens / 3s.
        XCTAssertEqual(tracker.rate(now: now)!, 80.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - Cumulative path (Codex)

    func testCumulativeDiffsAgainstBaseline() {
        var tracker = TokenRateTracker()
        tracker.append(cumulative(100, at: -4)) // baseline — no tokens yet
        tracker.append(cumulative(150, at: -2))
        tracker.append(cumulative(220, at: -1))

        // Deltas: 0 + 50 + 70 = 120 over the 4s since the oldest sample.
        let rate = try! XCTUnwrap(tracker.rate(now: now))
        XCTAssertEqual(rate, 30.0, accuracy: 0.001)
    }

    func testCumulativeSamplesReflectDiffsNotTotals() {
        var tracker = TokenRateTracker()
        tracker.append(cumulative(100, at: -3))
        tracker.append(cumulative(150, at: -1))

        // Baseline event carries zero; the growth is attributed to the later event.
        XCTAssertEqual(tracker.samples.map(\.tokens), [0, 50])
    }

    func testCumulativeResetRebasesWithoutNegative() {
        var tracker = TokenRateTracker()
        tracker.append(cumulative(150, at: -4))
        tracker.append(cumulative(100, at: -2)) // resume/compact: counter restarted
        tracker.append(cumulative(130, at: -1))

        XCTAssertEqual(tracker.samples.map(\.tokens), [0, 0, 30])
    }

    func testCumulativeReplayIgnored() {
        var tracker = TokenRateTracker()
        tracker.append(cumulative(150, at: -2))
        tracker.append(cumulative(150, at: -2)) // truncated file replayed from byte 0
        tracker.append(cumulative(180, at: -1))

        XCTAssertEqual(tracker.samples.map(\.tokens), [0, 30])
    }

    // MARK: - Windows and staleness

    func testRateWindowExcludesOldSamples() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(1000, at: -30, id: "old"))
        tracker.append(perMessage(100, at: -5, id: "new"))

        XCTAssertEqual(tracker.rate(now: now), 20) // only 100 / 5s counts
    }

    func testSampleBufferPrunesAncientEntries() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(1, at: -300, id: "ancient"))
        tracker.append(perMessage(2, at: -1, id: "fresh"))

        XCTAssertEqual(tracker.samples.count, 1)
        XCTAssertEqual(tracker.samples.first?.tokens, 2)
    }

    // MARK: - rateText (badge rendering)

    func testRateTextRendersWhileGenerating() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(300, at: -2, id: "a"))

        XCTAssertEqual(TokenRateTracker.rateText(samples: tracker.samples, now: now), "150 tok/s")
    }

    func testRateTextHiddenWhenStale() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(300, at: -9, id: "a"))

        XCTAssertNil(TokenRateTracker.rateText(samples: tracker.samples, now: now))
    }

    func testRateTextHiddenBelowThreshold() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(2, at: -9, id: "a"))

        XCTAssertNil(TokenRateTracker.rateText(samples: tracker.samples, now: now)) // 0.22 tok/s
    }

    func testRateTextHiddenWithNoSamples() {
        XCTAssertNil(TokenRateTracker.rateText(samples: [], now: now))
    }

    // MARK: - health (collapsed-pill signal)

    func testHealthFlowingWhenFreshAndFast() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(500, at: -2, id: "a")) // 250 tok/s

        XCTAssertEqual(tracker.health(now: now), .flowing)
    }

    func testHealthSlowWhenFreshButCrawling() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(5, at: -2, id: "a")) // 2.5 tok/s

        XCTAssertEqual(tracker.health(now: now), .slow)
    }

    func testHealthStalledWhenSilentWithoutTool() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(500, at: -20, id: "a"))

        XCTAssertEqual(tracker.health(now: now), .stalled)
    }

    func testHealthSuppressedWhileToolRunning() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(500, at: -20, id: "a"))

        // Tokens legitimately pause during tool execution — never a stall.
        XCTAssertEqual(tracker.health(now: now, toolRunning: true), .none)
    }

    func testHealthTransientGapIsNone() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(500, at: -10, id: "a")) // 8s < age < 15s

        XCTAssertEqual(tracker.health(now: now), .none)
    }

    func testHealthGivesUpAfterLongSilence() {
        var tracker = TokenRateTracker()
        tracker.append(perMessage(500, at: -90, id: "a"))

        XCTAssertEqual(tracker.health(now: now), .none)
    }

    func testHealthNoneWithoutSamples() {
        XCTAssertEqual(TokenRateTracker().health(now: now), .none)
    }

    func testCompactSlowTextOnlyForCrawlingRates() {
        var fast = TokenRateTracker()
        fast.append(perMessage(500, at: -2, id: "a"))
        XCTAssertNil(TokenRateTracker.compactSlowText(samples: fast.samples, now: now))

        var slow = TokenRateTracker()
        slow.append(perMessage(5, at: -2, id: "a"))
        XCTAssertEqual(TokenRateTracker.compactSlowText(samples: slow.samples, now: now), "2 t/s")

        var trickle = TokenRateTracker()
        trickle.append(perMessage(1, at: -5, id: "a"))
        XCTAssertEqual(TokenRateTracker.compactSlowText(samples: trickle.samples, now: now), "<1 t/s")

        var stale = TokenRateTracker()
        stale.append(perMessage(5, at: -30, id: "a"))
        XCTAssertNil(TokenRateTracker.compactSlowText(samples: stale.samples, now: now))
    }
}
