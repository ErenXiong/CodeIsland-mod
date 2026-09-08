import Foundation

public struct CodexUsageTotals: Equatable, Sendable {
    public var inputTokens = 0
    public var cachedInputTokens = 0
    public var cacheWriteInputTokens = 0
    public var outputTokens = 0
    public var reasoningOutputTokens = 0
    public var eventCount = 0

    public var isEmpty: Bool { eventCount == 0 }

    public init() {}

    mutating func add(_ other: CodexUsageTotals) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteInputTokens += other.cacheWriteInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        eventCount += other.eventCount
    }
}

/// Token-usage aggregation over the local Codex session rollouts
/// (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) — local-first, no API calls.
///
/// Codex emits `event_msg` lines whose payload reports the SESSION-CUMULATIVE
/// token total so far (`info.total_token_usage`), streamed periodically while a
/// turn generates. The scanner stores the raw cumulative values and turns them
/// into per-window usage by differencing consecutive events, attributing each
/// delta to the later event's timestamp. The first event a file contributes to
/// the aggregation window only establishes the baseline (delta 0), and a total
/// that shrinks (resume / compact restarts the counter) rebases silently — no
/// path produces a negative sample.
///
/// Structure mirrors `ClaudeUsageScanner`: incremental FileCache keyed by file,
/// complete-lines-only consumption, mtime gating, hourly sparkline buckets.
public enum CodexUsageScanner {
    /// Sparkline resolution: one bucket per hour, oldest first.
    public static let sparklineHours = 12

    public struct Snapshot: Equatable, Sendable {
        public let last5h: CodexUsageTotals
        public let today: CodexUsageTotals
        /// Output tokens per hour for the trailing `sparklineHours` hours,
        /// index 0 oldest, last index = the current hour.
        public let hourlyOutputTokens: [Int]
        public let scannedAt: Date

        public init(last5h: CodexUsageTotals, today: CodexUsageTotals, hourlyOutputTokens: [Int], scannedAt: Date) {
            self.last5h = last5h
            self.today = today
            self.hourlyOutputTokens = hourlyOutputTokens
            self.scannedAt = scannedAt
        }
    }

    /// Per-file incremental parse state. Rollouts are append-only, so each
    /// rescan reads only the bytes past `consumedBytes`. Events keep the RAW
    /// cumulative totals; differencing happens at aggregation time so cutoff
    /// pruning can drop old events without double counting.
    public struct FileCache: Sendable {
        struct CachedEvent: Sendable {
            let timestamp: Date
            let usage: CodexUsageTotals // cumulative raw values
        }
        struct FileEntry: Sendable {
            var consumedBytes: UInt64 = 0
            var events: [CachedEvent] = []
        }
        var files: [String: FileEntry] = [:]
        public init() {}
    }

    /// Resolve Codex's config directory. Honors $CODEX_HOME (with a leading
    /// `~` expanded); empty or whitespace-only values are treated as unset.
    /// Mirrors `ConfigInstaller.codexHome()` in the app target — Core cannot
    /// depend on app types, so the two must be kept in sync.
    public static func codexHome() -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() + "/.codex" }
        return (raw as NSString).expandingTildeInPath
    }

    /// One-shot convenience (tests, callers without persistent state).
    public static func scan(
        codexHome: String = codexHome(),
        now: Date = Date()
    ) -> Snapshot {
        var cache = FileCache()
        return scan(codexHome: codexHome, now: now, cache: &cache)
    }

    public static func scan(
        codexHome: String = codexHome(),
        now: Date = Date(),
        cache: inout FileCache
    ) -> Snapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 3600)
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart)

        var last5h = CodexUsageTotals()
        var today = CodexUsageTotals()
        var hourly = [Int](repeating: 0, count: sparklineHours)
        var activeFiles = Set<String>()

        let fm = FileManager.default
        let sessionsDir = codexHome + "/sessions"
        for year in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] {
            let yearPath = sessionsDir + "/" + year
            for month in (try? fm.contentsOfDirectory(atPath: yearPath)) ?? [] {
                let monthPath = yearPath + "/" + month
                for day in (try? fm.contentsOfDirectory(atPath: monthPath)) ?? [] {
                    let dayPath = monthPath + "/" + day
                    // Day-directory pruning: a rollout day that ended before the
                    // cutoff can't hold in-window events. Unparseable names are
                    // still traversed (forward compatibility).
                    if let dayEnd = endOfDay(year: year, month: month, day: day), dayEnd < cutoff {
                        continue
                    }
                    for file in (try? fm.contentsOfDirectory(atPath: dayPath)) ?? [] {
                        guard file.hasSuffix(".jsonl") else { continue }
                        let path = dayPath + "/" + file
                        // mtime gate: untouched-since-cutoff rollouts can't
                        // contain in-window events.
                        guard let attrs = try? fm.attributesOfItem(atPath: path),
                              let mtime = attrs[.modificationDate] as? Date,
                              mtime >= cutoff else { continue }
                        activeFiles.insert(path)
                        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                        var entry = cache.files[path] ?? FileCache.FileEntry()
                        if size < entry.consumedBytes {
                            // Truncated or replaced — start over.
                            entry = FileCache.FileEntry()
                        }
                        if size > entry.consumedBytes {
                            consumeNewLines(path: path, into: &entry)
                        }
                        entry.events.removeAll { $0.timestamp < cutoff }
                        cache.files[path] = entry

                        // Differencing: each retained event contributes the
                        // growth since the previous event in the same file.
                        var previous: CodexUsageTotals?
                        for event in entry.events where event.timestamp <= now {
                            var delta = CodexUsageTotals()
                            if let prev = previous, isMonotonic(event.usage, over: prev) {
                                delta = difference(event.usage, from: prev)
                                delta.eventCount = 1
                            }
                            // Either the window's first event (baseline only) or
                            // a reset — delta stays zero, baseline still advances.
                            previous = event.usage

                            if delta.isEmpty { continue }
                            if event.timestamp >= fiveHoursAgo { last5h.add(delta) }
                            if event.timestamp >= midnight { today.add(delta) }
                            let hoursAgo = Int(now.timeIntervalSince(event.timestamp) / 3600)
                            if hoursAgo >= 0 && hoursAgo < sparklineHours {
                                hourly[sparklineHours - 1 - hoursAgo] += delta.outputTokens
                            }
                        }
                    }
                }
            }
        }
        // Files that fell out of the mtime window carry no in-window events.
        cache.files = cache.files.filter { activeFiles.contains($0.key) }
        return Snapshot(last5h: last5h, today: today, hourlyOutputTokens: hourly, scannedAt: now)
    }

    /// Read bytes past `entry.consumedBytes` and parse the COMPLETE lines only —
    /// a partial trailing line (writer mid-append) is left for the next scan.
    private static func consumeNewLines(path: String, into entry: inout FileCache.FileEntry) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: entry.consumedBytes)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let consumable = data[data.startIndex...lastNewline]
        entry.consumedBytes += UInt64(consumable.count)
        guard let text = String(data: consumable, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            if let parsed = parseTokenCountLine(String(line)) {
                entry.events.append(.init(timestamp: parsed.timestamp, usage: parsed.usage))
            }
        }
    }

    /// Parse one rollout line into (timestamp, cumulative usage) — nil for every
    /// non-token_count line (the bulk of a rollout: response_item, turn_context…).
    static func parseTokenCountLine(_ line: String) -> (timestamp: Date, usage: CodexUsageTotals)? {
        // Cheap pre-filter before full JSON decoding.
        guard line.contains("\"token_count\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestampRaw = obj["timestamp"] as? String,
              let timestamp = ClaudeUsageScanner.parseISO8601(timestampRaw),
              let info = payload["info"] as? [String: Any],
              let totals = info["total_token_usage"] as? [String: Any]
        else { return nil }

        var usage = CodexUsageTotals()
        usage.inputTokens = totals["input_tokens"] as? Int ?? 0
        usage.cachedInputTokens = totals["cached_input_tokens"] as? Int ?? 0
        usage.cacheWriteInputTokens = totals["cache_write_input_tokens"] as? Int ?? 0
        usage.outputTokens = totals["output_tokens"] as? Int ?? 0
        usage.reasoningOutputTokens = totals["reasoning_output_tokens"] as? Int ?? 0
        return (timestamp, usage)
    }

    /// A cumulative total only diffs against its predecessor when every field
    /// moved forward; anything less means the counter restarted (resume/compact).
    private static func isMonotonic(_ current: CodexUsageTotals, over previous: CodexUsageTotals) -> Bool {
        current.inputTokens >= previous.inputTokens
            && current.cachedInputTokens >= previous.cachedInputTokens
            && current.cacheWriteInputTokens >= previous.cacheWriteInputTokens
            && current.outputTokens >= previous.outputTokens
            && current.reasoningOutputTokens >= previous.reasoningOutputTokens
    }

    private static func difference(_ current: CodexUsageTotals, from previous: CodexUsageTotals) -> CodexUsageTotals {
        var delta = CodexUsageTotals()
        delta.inputTokens = current.inputTokens - previous.inputTokens
        delta.cachedInputTokens = current.cachedInputTokens - previous.cachedInputTokens
        delta.cacheWriteInputTokens = current.cacheWriteInputTokens - previous.cacheWriteInputTokens
        delta.outputTokens = current.outputTokens - previous.outputTokens
        delta.reasoningOutputTokens = current.reasoningOutputTokens - previous.reasoningOutputTokens
        return delta
    }

    private static func endOfDay(year: String, month: String, day: String) -> Date? {
        guard let y = Int(year), let m = Int(month), let d = Int(day),
              let start = Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) else {
            return nil
        }
        return start.addingTimeInterval(24 * 3600)
    }
}
