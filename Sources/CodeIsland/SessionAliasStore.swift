import Foundation

/// Durable, user-assigned nicknames for sessions ("api-debug", "wife's bot…").
///
/// Keyed by session id in a single UserDefaults dictionary — deliberately NOT
/// part of `SessionPersistence`, so an alias survives session cleanup, app
/// restarts, and (for Claude) `resume` with the same id. Codex mints a new
/// session id on resume, so its aliases don't carry over; accepted trade-off.
enum SessionAliasStore {
    private static let key = "sessionAliases"

    static func alias(for sessionId: String) -> String? {
        aliases()[sessionId]
    }

    static func setAlias(_ alias: String?, for sessionId: String) {
        var all = aliases()
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            all.removeValue(forKey: sessionId)
        } else {
            all[sessionId] = String(trimmed.prefix(24))
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    private static func aliases() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
