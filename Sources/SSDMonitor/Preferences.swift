import AppKit
import ServiceManagement

enum Preferences {
    private static let soundKey = "alertSound"
    private static let loginSetUpKey = "loginItemSetUp"
    private static let requireKey = "requireSSDSnoozedUntil"
    private static let welcomeKey = "welcomeAnswered"
    static let defaultSound = "Sosumi"

    /// "Require the SSD" (on by default): nil = on; a date = snoozed until then, `.distantFuture` = off until
    /// turned back on. Kept across restarts; a snooze that has run out counts as on.
    static var requireSnoozedUntil: Date? {
        get { UserDefaults.standard.object(forKey: requireKey) as? Date }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: requireKey) }
            else { UserDefaults.standard.removeObject(forKey: requireKey) }
        }
    }

    static var requireSSD: Bool { requireSnoozedUntil.map { $0 <= Date() } ?? true }

    /// The welcome screen (set up the sudo rule) was answered: set up, "Not now", or closed. It is shown once.
    static var welcomeAnswered: Bool {
        get { UserDefaults.standard.bool(forKey: welcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: welcomeKey) }
    }

    /// The alarm sound's name, or nil for no sound.
    static var alertSound: String? {
        get {
            let value = UserDefaults.standard.string(forKey: soundKey) ?? defaultSound
            return value.isEmpty ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: soundKey) }
    }

    /// macOS alert sounds (system and the user's own), by name.
    static func availableSounds() -> [String] {
        let dirs = ["/System/Library/Sounds", Paths.home + "/Library/Sounds"]
        let names = dirs.flatMap { dir -> [String] in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return files.filter { ["aiff", "aif", "wav", "caf", "m4a"].contains(($0 as NSString).pathExtension.lowercased()) }
                .map { ($0 as NSString).deletingPathExtension }
        }
        return Array(Set(names)).sorted()
    }

    // MARK: - launch at login

    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    static var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("launch at login \(on ? "on" : "off")")
        } catch {
            Log.write("launch at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
    }

    /// Turn launch at login on once, the first time the app runs. Afterwards the menu decides.
    static func setUpLaunchAtLoginOnce() {
        guard !UserDefaults.standard.bool(forKey: loginSetUpKey) else { return }
        UserDefaults.standard.set(true, forKey: loginSetUpKey)
        setLaunchAtLogin(true)
    }
}

/// Plays the alarm sound a number of times, one after the other. The sound is loaded only to play it.
@MainActor
final class AlertSound: NSObject, NSSoundDelegate {
    private var sound: NSSound?
    private var remaining = 0

    func play(times: Int = 3, name: String? = Preferences.alertSound) {
        stop()
        guard let name, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        self.sound = sound
        remaining = times - 1
        sound.delegate = self
        sound.play()
    }

    func stop() {
        sound?.delegate = nil
        sound?.stop()
        sound = nil
        remaining = 0
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        guard sound === self.sound, finished, remaining > 0 else {
            if sound === self.sound { self.sound = nil }
            return
        }
        remaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.sound === sound else { return }
            sound.play()
        }
    }
}
