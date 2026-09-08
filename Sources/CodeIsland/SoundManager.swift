import AppKit

/// Plays 8-bit sound effects in response to hook events
@MainActor
class SoundManager {
    static let shared = SoundManager()

    private let defaults = UserDefaults.standard

    /// Map event names to 8-bit WAV file names (without extension)
    static let eventSounds: [(event: String, sound: String, key: String, label: String)] = [
        ("SessionStart",      "8bit_start",    SettingsKey.soundSessionStart,   "会话开始"),
        ("TaskRoundComplete", "8bit_complete",  SettingsKey.soundTaskComplete,   "任务完成"),
        ("Stop",              "8bit_complete",  SettingsKey.soundTaskComplete,   "任务完成"),
        ("PostToolUseFailure","8bit_error",     SettingsKey.soundTaskError,      "任务错误"),
        ("PermissionRequest", "8bit_approval",  SettingsKey.soundApprovalNeeded, "需要审批"),
        ("UserPromptSubmit",  "8bit_submit",    SettingsKey.soundPromptSubmit,   "任务确认"),
        ("Stalled",           "8bit_stalled",   SettingsKey.soundStalled,        "输出停滞"),
    ]

    private var soundCache: [String: NSSound] = [:]

    /// Where a *decided* event sound goes. Production plays it; a test installs
    /// a recorder and asserts on the names it receives.
    ///
    /// Only the play step is swappable — everything above it (master toggle,
    /// quiet hours, the per-event toggle, and the caller's own "is this the
    /// start of a burst" decision) stays the code under test. That decision is
    /// not the same question as "should a card open", and it has already drifted
    /// once behind a shared `if` with nothing able to catch it. (#312)
    ///
    /// Deliberately not used by `preview` / `previewCustom`: those are direct UI
    /// actions, and folding them in here would make a recorder pick up button
    /// presses as if they were event sounds.
    var playSink: ((String) -> Void)?

    private func emit(_ soundName: String) {
        if let playSink {
            playSink(soundName)
            return
        }
        play(soundName)
    }

    private init() {
        // Pre-load all sounds into cache
        for entry in Self.eventSounds {
            if let sound = loadSound(entry.sound) {
                soundCache[entry.sound] = sound
            }
        }
    }

    /// Called from AppState.handleEvent() to trigger appropriate sounds
    func handleEvent(_ eventName: String) {
        guard defaults.bool(forKey: SettingsKey.soundEnabled) else { return }
        guard !quietHoursActive else { return }
        guard let entry = Self.eventSounds.first(where: { $0.event == eventName }) else { return }
        guard defaults.bool(forKey: entry.key) else { return }
        emit(entry.sound)
    }

    /// Play boot sound on app launch
    func playBoot() {
        guard defaults.bool(forKey: SettingsKey.soundEnabled) else { return }
        guard !quietHoursActive else { return }
        guard defaults.bool(forKey: SettingsKey.soundBoot) else { return }
        emit("8bit_boot")
    }

    /// Quiet-hours window test. Half-open [start, end) in minutes since
    /// midnight; start > end spans midnight; start == end never mutes (an
    /// all-day window would just be the master sound toggle).
    nonisolated static func isInQuietHours(minutesSinceMidnight m: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return m >= start && m < end }
        return m >= start || m < end
    }

    /// Settings previews stay audible: only event-driven sounds are gated.
    private var quietHoursActive: Bool {
        guard defaults.bool(forKey: SettingsKey.quietHoursEnabled) else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Self.isInQuietHours(
            minutesSinceMidnight: (comps.hour ?? 0) * 60 + (comps.minute ?? 0),
            start: storedMinutes(SettingsKey.quietHoursStart, default: SettingsDefaults.quietHoursStart),
            end: storedMinutes(SettingsKey.quietHoursEnd, default: SettingsDefaults.quietHoursEnd)
        )
    }

    /// integer(forKey:) collapses "never set" to 0 (midnight) — fall back to
    /// the SettingsDefaults the UI shows instead.
    private func storedMinutes(_ key: String, default def: Int) -> Int {
        defaults.object(forKey: key) == nil ? def : defaults.integer(forKey: key)
    }

    /// Preview a specific sound (used by settings UI play buttons)
    func preview(_ soundName: String) {
        play(soundName)
    }

    /// Preview a custom sound file by path (used by settings UI)
    func previewCustom(_ path: String) {
        guard let sound = NSSound(contentsOfFile: path, byReference: false) else {
            NSSound.beep()
            return
        }
        if sound.isPlaying { sound.stop() }
        let volume = defaults.integer(forKey: SettingsKey.soundVolume)
        sound.volume = Float(volume) / 100.0
        sound.play()
    }

    /// Play a named 8-bit WAV with volume control, checking for custom sound first
    private func play(_ name: String) {
        let sound: NSSound? = loadCustomSound(name) ?? soundCache[name] ?? loadSound(name)
        guard let sound else {
            NSSound.beep()
            return
        }
        if sound.isPlaying { sound.stop() }
        let volume = defaults.integer(forKey: SettingsKey.soundVolume)
        sound.volume = Float(volume) / 100.0
        sound.play()
    }

    /// Load a custom sound from user-specified path
    private func loadCustomSound(_ name: String) -> NSSound? {
        guard let path = defaults.string(forKey: SettingsKey.soundCustomPath(name)),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return NSSound(contentsOfFile: path, byReference: false)
    }

    /// Load a WAV from the SPM resource bundle
    private func loadSound(_ name: String) -> NSSound? {
        // SPM generates Bundle.appModule for resource bundles
        // Resources are inside CodeIsland_CodeIsland.bundle/Resources/
        if let url = Bundle.appModule.url(forResource: name, withExtension: "wav", subdirectory: "Resources") {
            return NSSound(contentsOf: url, byReference: false)
        }
        // Fallback: try without subdirectory
        if let url = Bundle.appModule.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }
        return nil
    }
}
