import Foundation

/// How well an agent's output is flowing right now — drives the collapsed-pill
/// indicator. Derived purely from token samples; "no signal" covers everything
/// the samples can't explain (idle, tool running, turn long dead).
public enum RateHealth: Equatable, Sendable {
    /// Fresh samples at a healthy rate — actively streaming.
    case flowing
    /// Fresh samples but crawling (weak network / overloaded endpoint).
    case slow
    /// Output went silent mid-turn with no tool running — likely stalled.
    case stalled
    /// No signal.
    case none
}

/// One output-token observation extracted from a transcript line.
///
/// Claude assistant lines carry per-message usage (`isCumulative == false`,
/// `messageId` set); Codex `token_count` events carry session-cumulative
/// totals (`isCumulative == true`, `messageId` nil).
public struct TokenSample: Equatable, Sendable {
    public let timestamp: Date
    public let outputTokens: Int
    public let isCumulative: Bool
    public let messageId: String?

    public init(timestamp: Date, outputTokens: Int, isCumulative: Bool, messageId: String? = nil) {
        self.timestamp = timestamp
        self.outputTokens = outputTokens
        self.isCumulative = isCumulative
        self.messageId = messageId
    }
}

/// Per-session output-token rate (tok/s) over a sliding window.
///
/// Fed exclusively by transcript-tail deltas (`ConversationTailDelta.tokenSamples`),
/// so it lives inside `SessionSnapshot` as a plain value — mutated only on the
/// main actor, never persisted, and torn down with its session.
///
/// Two ingest paths share one sample buffer:
/// - **Per-message** (Claude): each assistant line's `message.usage` is a complete
///   count for that API response. Deduped on `messageId` — continuation lines of
///   the same response repeat both the id and the usage.
/// - **Cumulative** (Codex): `token_count` events report the session total so far;
///   the per-sample delta is the difference from the previous event. The first
///   observed event only establishes the baseline. A total that shrinks (resume /
///   compact restarts the counter) rebases silently — never a negative delta.
/// Replay guards exist for both paths because a truncate/inode swap re-reads the
/// file from byte 0 (`JSONLTailer`), which would otherwise resurface old lines
/// as a burst of phantom tokens.
public struct TokenRateTracker: Sendable, Equatable {
    public struct Sample: Equatable, Sendable {
        public let timestamp: Date
        public let tokens: Int
    }

    /// Keep at most this many window samples (each covers ≥ 1s of streaming).
    private static let maxSamples = 32
    /// Samples older than this stop contributing to the rate.
    private static let maxSampleAge: TimeInterval = 60
    /// Bounded FIFO capacity for both dedupe keys.
    private static let dedupeCapacity = 64
    /// Nothing renders when the newest sample is older than this — the badge
    /// disappears ~8s after generation stops.
    private static let stalenessLimit: TimeInterval = 8
    /// Rates below this are noise (a few tokens trickling through caches).
    private static let minimumRate = 1.0
    /// Output rates below this read as crawling rather than flowing.
    public static let slowRateThreshold = 10.0
    /// Silence longer than this mid-turn (with no tool running) reads as stalled.
    public static let stalledAfter: TimeInterval = 15
    /// Past this much silence the turn is considered dead rather than stalled —
    /// session idleness is the session card's job, not the collapsed pill's.
    public static let stalledGiveUpAfter: TimeInterval = 60

    public private(set) var samples: [Sample] = []
    private var lastCumulative: Int?
    private var seenMessageIds: [String] = []
    private var seenCumulativeKeys: [Date: Int] = [:]
    private var cumulativeKeyOrder: [Date] = []

    public init() {}

    public mutating func append(_ sample: TokenSample) {
        if sample.isCumulative {
            guard dedupeCumulative(sample) else { return }
            let tokens: Int
            if let last = lastCumulative {
                // Counter went backwards (resume/compact): rebase, no delta.
                tokens = max(sample.outputTokens - last, 0)
            } else {
                tokens = 0 // First observation only sets the baseline.
            }
            lastCumulative = sample.outputTokens
            push(Sample(timestamp: sample.timestamp, tokens: tokens))
        } else {
            if let id = sample.messageId {
                guard !seenMessageIds.contains(id) else { return }
                seenMessageIds.append(id)
                if seenMessageIds.count > Self.dedupeCapacity {
                    seenMessageIds.removeFirst(seenMessageIds.count - Self.dedupeCapacity)
                }
            }
            push(Sample(timestamp: sample.timestamp, tokens: max(sample.outputTokens, 0)))
        }
    }

    /// Output tokens per second across the trailing `window` seconds, or nil when
    /// there is nothing recent enough. The divisor grows with `now - oldest`, so
    /// the displayed rate decays toward zero while generation stalls.
    public func rate(now: Date, window: TimeInterval = 10) -> Double? {
        let cutoff = now.addingTimeInterval(-window)
        let recent = samples.filter { $0.timestamp > cutoff }
        guard let oldest = recent.first?.timestamp else { return nil }
        let total = recent.reduce(0) { $0 + $1.tokens }
        let elapsed = max(now.timeIntervalSince(oldest), 1.0)
        return Double(total) / elapsed
    }

    /// Rendered badge text for the given samples, or nil when the badge should
    /// stay hidden (idle, stale, or sub-threshold rate). Static so a SwiftUI
    /// `TimelineView` can re-evaluate it every second without mutating state.
    public static func rateText(samples: [Sample], now: Date) -> String? {
        guard let newest = samples.last?.timestamp,
              now.timeIntervalSince(newest) <= stalenessLimit else { return nil }
        var tracker = TokenRateTracker()
        tracker.samples = samples
        guard let rate = tracker.rate(now: now), rate >= minimumRate else { return nil }
        return "\(Int(rate)) tok/s"
    }

    /// Flow-health signal for the collapsed pill. `toolRunning` suppresses the
    /// stalled verdict — tokens legitimately pause while a Bash command or edit
    /// runs, and that must not read as a stall.
    public func health(now: Date, toolRunning: Bool = false) -> RateHealth {
        guard let newest = samples.last?.timestamp else { return .none }
        let age = now.timeIntervalSince(newest)
        if age <= Self.stalenessLimit {
            guard let rate = rate(now: now) else { return .none }
            return rate >= Self.slowRateThreshold ? .flowing : .slow
        }
        if age > Self.stalledGiveUpAfter { return .none }
        if toolRunning { return .none }
        return age >= Self.stalledAfter ? .stalled : .none
    }

    /// Tiny collapsed-badge text for a crawling rate ("7 t/s", "<1 t/s"), or
    /// nil unless the samples are fresh AND slow — the flowing state stays
    /// silent, and staleness is the stalled dot's business.
    public static func compactSlowText(samples: [Sample], now: Date) -> String? {
        guard let newest = samples.last?.timestamp,
              now.timeIntervalSince(newest) <= stalenessLimit else { return nil }
        var tracker = TokenRateTracker()
        tracker.samples = samples
        guard let rate = tracker.rate(now: now), rate < slowRateThreshold else { return nil }
        return rate < 1 ? "<1 t/s" : "\(Int(rate)) t/s"
    }

    private mutating func push(_ sample: Sample) {
        samples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-Self.maxSampleAge)
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    /// True on first sight; false when a replayed (timestamp, total) pair arrives.
    private mutating func dedupeCumulative(_ sample: TokenSample) -> Bool {
        if seenCumulativeKeys[sample.timestamp] == sample.outputTokens { return false }
        seenCumulativeKeys[sample.timestamp] = sample.outputTokens
        cumulativeKeyOrder.append(sample.timestamp)
        if cumulativeKeyOrder.count > Self.dedupeCapacity {
            let droppedCount = cumulativeKeyOrder.count - Self.dedupeCapacity
            let dropped = Array(cumulativeKeyOrder.prefix(droppedCount))
            cumulativeKeyOrder.removeFirst(droppedCount)
            for key in dropped { seenCumulativeKeys.removeValue(forKey: key) }
        }
        return true
    }
}
