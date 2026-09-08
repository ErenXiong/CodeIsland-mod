import XCTest
@testable import CodeIslandCore

final class CodexUsageScannerTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "codex-usage-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Noon local time keeps "1h ago" and "8h ago" unambiguously on today's
    /// date regardless of when the test runs.
    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    /// Rollout path under sessions/YYYY/MM/DD for the given date.
    private func rolloutPath(for date: Date, name: String = "rollout-test.jsonl") throws -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let dir = home + "/sessions/\(comps.year!)/\(String(format: "%02d", comps.month!))/\(String(format: "%02d", comps.day!))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/" + name
    }

    /// Real token_count line shape (verified against live codex rollouts).
    private func tokenLine(at date: Date, input: Int, cached: Int = 0, cacheWrite: Int = 0,
                           output: Int, reasoning: Int = 0) -> String {
        """
        {"timestamp":"\(iso(date))","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":\(cacheWrite),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":\(cacheWrite),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)}}}}
        """
    }

    // MARK: - Parsing

    func testParseTokenCountLine() {
        let parsed = try! XCTUnwrap(CodexUsageScanner.parseTokenCountLine(
            tokenLine(at: noon, input: 8670, cached: 576, cacheWrite: 12, output: 82, reasoning: 20)))
        XCTAssertEqual(parsed.usage.inputTokens, 8670)
        XCTAssertEqual(parsed.usage.cachedInputTokens, 576)
        XCTAssertEqual(parsed.usage.cacheWriteInputTokens, 12)
        XCTAssertEqual(parsed.usage.outputTokens, 82)
        XCTAssertEqual(parsed.usage.reasoningOutputTokens, 20)

        // The bulk of a rollout is other event kinds — all rejected.
        XCTAssertNil(CodexUsageScanner.parseTokenCountLine(
            #"{"timestamp":"2026-09-08T02:52:19.053Z","type":"response_item","payload":{}}"#))
        XCTAssertNil(CodexUsageScanner.parseTokenCountLine(
            #"{"timestamp":"2026-09-08T02:52:19.053Z","type":"event_msg","payload":{"type":"task_complete"}}"#))
        XCTAssertNil(CodexUsageScanner.parseTokenCountLine("not json"))
    }

    // MARK: - Aggregation

    func testScanDiffsCumulativeTotals() throws {
        let now = noon
        let path = try rolloutPath(for: now)
        // Cumulative totals: 10→15→22 output ⇒ deltas 0, 5, 7. (Trailing
        // newline matters: the scanner only consumes complete lines.)
        try ([
            tokenLine(at: now.addingTimeInterval(-3600), input: 1000, output: 10),
            tokenLine(at: now.addingTimeInterval(-1800), input: 1500, output: 15),
            tokenLine(at: now.addingTimeInterval(-600), input: 2200, output: 22),
        ].joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let snap = CodexUsageScanner.scan(codexHome: home, now: now)

        XCTAssertEqual(snap.last5h.inputTokens, 1200) // 1500-1000 + 2200-1500
        XCTAssertEqual(snap.last5h.outputTokens, 12)
        XCTAssertEqual(snap.last5h.eventCount, 2)
        XCTAssertEqual(snap.today.outputTokens, 12)
        // Sparkline: both deltas are <1h old (30min and 10min), so both land in
        // the current-hour bucket.
        let last = CodexUsageScanner.sparklineHours - 1
        XCTAssertEqual(snap.hourlyOutputTokens[last], 12)
        XCTAssertEqual(snap.hourlyOutputTokens.reduce(0, +), 12)
    }

    func testCumulativeResetRebasesWithoutNegative() throws {
        let now = noon
        let path = try rolloutPath(for: now)
        try ([
            tokenLine(at: now.addingTimeInterval(-1800), input: 5000, output: 150),
            // Counter restarted below its previous value (resume/compact).
            tokenLine(at: now.addingTimeInterval(-900), input: 100, output: 50),
            tokenLine(at: now.addingTimeInterval(-300), input: 400, output: 80),
        ].joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let snap = CodexUsageScanner.scan(codexHome: home, now: now)

        // Reset event contributes zero; only the growth after it counts.
        XCTAssertEqual(snap.last5h.inputTokens, 300)
        XCTAssertEqual(snap.last5h.outputTokens, 30)
    }

    // MARK: - Incremental behavior

    func testIncrementalScanReadsOnlyAppendedBytes() throws {
        let now = noon
        let path = try rolloutPath(for: now)
        try (tokenLine(at: now.addingTimeInterval(-3600), input: 1000, output: 10) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = CodexUsageScanner.FileCache()
        let first = CodexUsageScanner.scan(codexHome: home, now: now, cache: &cache)
        XCTAssertEqual(first.last5h.outputTokens, 0) // baseline only
        let consumedAfterFirst = try XCTUnwrap(cache.files[path]?.consumedBytes)
        XCTAssertGreaterThan(consumedAfterFirst, 0)

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((tokenLine(at: now.addingTimeInterval(-1800), input: 1500, output: 15) + "\n").utf8))
        handle.closeFile()

        let second = CodexUsageScanner.scan(codexHome: home, now: now, cache: &cache)
        XCTAssertEqual(second.last5h.outputTokens, 5)
        XCTAssertGreaterThan(try XCTUnwrap(cache.files[path]?.consumedBytes), consumedAfterFirst)
    }

    func testIncrementalScanIgnoresPartialTrailingLine() throws {
        let now = noon
        let path = try rolloutPath(for: now)
        let full = tokenLine(at: now.addingTimeInterval(-3600), input: 1000, output: 10) + "\n"
        let partial = "{\"timestamp\":\"2026-09-08T02:52" // writer mid-append
        try (full + partial).write(toFile: path, atomically: true, encoding: .utf8)

        var cache = CodexUsageScanner.FileCache()
        let snap = CodexUsageScanner.scan(codexHome: home, now: now, cache: &cache)
        XCTAssertTrue(snap.last5h.isEmpty)
        XCTAssertEqual(cache.files[path]?.consumedBytes, UInt64(full.utf8.count))
    }

    func testTruncatedFileIsRescannedFromStart() throws {
        let now = noon
        let path = try rolloutPath(for: now)
        try (tokenLine(at: now.addingTimeInterval(-3600), input: 1000, output: 10) + "\n"
             + tokenLine(at: now.addingTimeInterval(-1800), input: 1500, output: 15) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = CodexUsageScanner.FileCache()
        _ = CodexUsageScanner.scan(codexHome: home, now: now, cache: &cache)

        // Replace with a shorter file (rollout rewritten).
        try (tokenLine(at: now.addingTimeInterval(-600), input: 20, output: 2) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = CodexUsageScanner.scan(codexHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.last5h.inputTokens, 0)
        XCTAssertEqual(snap.last5h.eventCount, 0)
    }

    func testScanEmptyHome() {
        let snap = CodexUsageScanner.scan(codexHome: home + "/nonexistent", now: noon)
        XCTAssertTrue(snap.last5h.isEmpty)
        XCTAssertTrue(snap.today.isEmpty)
    }

    func testStaleDayDirectoryIsPrunedButOddNamesStillTraversed() throws {
        let now = noon
        // A day folder that ended long before the cutoff — even with a fresh
        // mtime it must be skipped by day-directory pruning.
        let staleDir = home + "/sessions/2025/01/01"
        try FileManager.default.createDirectory(atPath: staleDir, withIntermediateDirectories: true)
        try (tokenLine(at: now.addingTimeInterval(-3600), input: 9999, output: 999) + "\n")
            .write(toFile: staleDir + "/rollout-stale.jsonl", atomically: true, encoding: .utf8)

        // Unparseable directory names are still traversed (forward compat):
        // this file must be consumed (baseline recorded) even though the
        // enclosing folder isn't a YYYY/MM/DD date. The rollout still needs
        // the full Y/M/D depth below the odd-named root.
        let oddDir = home + "/sessions/not-a-date/x/y"
        try FileManager.default.createDirectory(atPath: oddDir, withIntermediateDirectories: true)
        let oddPath = oddDir + "/rollout-odd.jsonl"
        try (tokenLine(at: now.addingTimeInterval(-3600), input: 100, output: 10) + "\n")
            .write(toFile: oddPath, atomically: true, encoding: .utf8)

        var cache = CodexUsageScanner.FileCache()
        let snap = CodexUsageScanner.scan(codexHome: home, now: now, cache: &cache)

        XCTAssertTrue(snap.last5h.isEmpty) // baseline-only file contributes no delta
        XCTAssertEqual(try XCTUnwrap(cache.files[oddPath]?.consumedBytes), UInt64((tokenLine(at: now.addingTimeInterval(-3600), input: 100, output: 10) + "\n").utf8.count))
        XCTAssertNil(cache.files[staleDir + "/rollout-stale.jsonl"])
    }
}
