import AppKit

/// Run on the main queue after a delay, main-actor isolated.
func onMain(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
}

/// Decides what the SSD's state means and what to show:
/// - healthy: nothing on screen.
/// - a problem that lasts 3 s: the alarm overlay and sound, unless the SSD is going away on purpose.
/// - "Require the SSD" (on by default): no Dismiss; the screen stays until the SSD is back or the user snoozes
///   the mode, and also comes up (silently) once the SSD is away on purpose.
/// - the SSD back after an unplug (or a problem fixed in place): the resume, with its progress overlay.
/// Everything is driven by disk events. While the SSD is healthy there is no timer at all, except while the
/// Statistics window is open (it reads the SSD's counters once a second, and stops when it closes).
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    enum Phase {
        case idle       // nothing on screen, or the resume's success screen (a new problem replaces it)
        case alarm      // the alarm is on screen
        case busy       // a command for a button runs (remount, unmount, eject)
        case asking     // a screen waits for the user: a question, "safe to unplug", a stopped resume
        case resuming
    }
    enum IconState { case healthy, issue, waiting, busy, error }

    static let startupGrace: TimeInterval = 20   // at login macOS may still be mounting the SSD
    static let wakeGrace: TimeInterval = 10
    static let debounce: TimeInterval = 3         // a problem must last this long before the alarm
    static let markerLifetime: TimeInterval = 600 // a planned-unplug marker counts for a problem this soon after it
    static let maxAutoStarts = 3                  // resumes in a row without one finishing or the user acting
    static let lowSpaceYellow: UInt64 = 200_000_000_000
    static let lowSpaceRed: UInt64 = 100_000_000_000

    private(set) var volumes: [Volume] = []
    private(set) var health = Health.empty
    private(set) var configError: String?
    private(set) var phase: Phase = .idle {
        didSet {
            updateActivity()
            // Leaving a command or the resume: look again, since disk events were only noted meanwhile.
            if oldValue == .busy || oldValue == .resuming, phase != .busy, phase != .resuming { scheduleEvaluate() }
        }
    }
    var freeBytes: UInt64? { health.freeBytes }

    private var watcher: DiskWatcher?
    private var statusMenu: StatusMenu?
    private let overlay = Overlay()
    private let sound = AlertSound()
    private let passwordWatch = PasswordWatch()
    private var job: Job?
    private var runner: ResumeRunner?
    private var evaluatePending = false
    private var pendingCheck: (timer: DispatchSourceTimer, due: TimeInterval)?
    private var lastStepShown: ResumeRunner.Step?
    private var resumeScope: [String]?
    private var resumeStartedAt: Date?           // wall clock, to compare with the marker file's date
    private var autoStarts = 0                   // see autoResume
    private var shownAlarmKey = ""               // what the alarm on screen says (not rebuilt if unchanged)
    private var pendingSuccess: ResumeRunner.Summary?   // finished, waiting for a volume that dropped out at the end
    private var unmountedByApp = Set<String>()   // what this eject flow unmounted, even if back by now
    private var markerWatch: DispatchSourceFileSystemObject?
    private var termSignal: DispatchSourceSignal?
    private var snoozeTimer: DispatchSourceTimer?    // see updateSnoozeTimer
    private var snoozeTimerFor: Date?                // the snooze end it is set for
    private var askingIsSafeToUnplug = false         // the asking screen is the eject's "Safe to unplug"
    private var safeToUnplugRequires = false         // and it was built while "Require the SSD" was on
    private var statsWindow: StatsWindow?            // the windows exist only while open
    private var settingsWindow: SettingsWindow?
    private var setupWindow: SetupWindow?
    private let adminPasswordWatch = PasswordWatch()   // while a sudo rule change waits for the password
    private var adminTasks = 0
    private var activeAdmin: AdminTask?   // kept until osascript exits, so quitting can end it
    /// The setup is adding a rule and then checks it with its own trace: Statistics holds off its trace until
    /// that is done (the kernel allows one trace at a time).
    var sudoRuleVerifying = false {
        didSet {
            guard oldValue != sudoRuleVerifying, !quitting else { return }
            if sudoRuleVerifying { statsWindow?.holdTrace(); settingsWindow?.refresh() } else { sudoRuleChanged() }
        }
    }
    private var quitting = false
    /// The current attachment of the SSD (its disk driver's registry entry ID) and when it was plugged in, or nil
    /// if that was before the app saw it.
    private(set) var ssdAttachment: (id: UInt64?, at: Date?)?
    private var attachmentGeneration = 0    // the watcher's attachment count when it was noted
    private var attachmentChecked = false   // the first look since the app started has been taken
    private var firstLookAbsent = false     // the first look found no SSD (maybe only not listed yet)
    private var sawSSDAbsent = false        // an absence for sure: a later attachment is one the app saw happen
    let startedAt = Date()
    /// What fs_usage last showed about the rule in this run of the app: true = sudo ran it, false = sudo
    /// wanted a password although the file is there; nil = not tried since the file last changed.
    private(set) var sudoRuleWorks: Bool?
    private(set) var sudoRuleRefusal: String?   // what sudo said when it didn't run fs_usage

    /// "Require the SSD"'s snooze choices: the overlay's short label, the menu's, and the length (nil = off
    /// until turned back on).
    static let snoozeChoices: [(short: String, long: String, seconds: TimeInterval?)] = [
        ("10 min", "Snooze 10 minutes", 600), ("30 min", "Snooze 30 minutes", 1800),
        ("1 hour", "Snooze 1 hour", 3600), ("1 day", "Snooze 1 day", 86400),
        ("Forever", "Off until turned back on", nil),
    ]

    /// Seconds since boot, not counting sleep: a clock that can't be set back, for debounce and grace periods.
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // The current incident.
    private let launchedAt = AppController.uptime
    private var graceUntil = AppController.uptime + AppController.startupGrace
    private var problemSince: TimeInterval? { didSet { updateActivity() } }
    private var activity: NSObjectProtocol?
    private var activityOptions: ProcessInfo.ActivityOptions?
    private var seenConnected = false
    private var alarmed = Set<String>()          // volumes that were part of an alarm
    private var wasDisconnected = false          // the whole SSD was gone since the last resume started
    private var waitingForReplug = false         // the app's own eject: no alarm while the SSD is away
    private var plannedAway = false              // the SSD went away while ssd-off's marker was fresh
    private var dismissed: (bad: Set<String>, connected: Bool)?
    private var askingCovers = Set<String>()     // problems already there when the asking screen came up
    private var failedStep: ResumeRunner.Step?   // the asking screen is a stopped resume, stopped here
    private var remounted: [String] = []
    private var alarmNote: [String] = []
    private var lastBusy: [String] = []          // volumes the unmount left mounted
    private var lastBusyWhy: [String] = []       // and diskutil's reason for each

    // MARK: - launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.changeCurrentDirectoryPath("/")
        Log.write("start, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        statusMenu = StatusMenu(controller: self)

        passwordWatch.onChange = { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self else { return }
                if visible { self.job?.pauseTimeout(); self.overlay.hide(for: "job") } else { self.job?.resumeTimeout(); self.overlay.unhide(for: "job") }
                self.statusMenu?.refresh()
            }
        }

        adminPasswordWatch.onChange = { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self else { return }
                if visible { self.overlay.hide(for: "admin") } else { self.overlay.unhide(for: "admin") }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.write("wake")
                self.graceUntil = AppController.uptime + AppController.wakeGrace
                self.problemSince = nil
                self.checkAgain(after: AppController.wakeGrace)
            }
        }

        // SIGTERM (`pkill`, the installer) quits the normal way, so a running command is stopped first.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSignal = term

        Preferences.setUpLaunchAtLoginOnce()
        UI.installMainMenu(settings: (self, #selector(openSettingsAction(_:))))
        loadVolumes()
        statusMenu?.refresh()
        showWelcomeOnce()
    }

    /// Quitting while a command runs (the menu, or an update): stop it and everything it started first, so
    /// nothing keeps mounting or unmounting with nobody watching. Takes at most a third of a second.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true   // nothing may start a trace from here on
        if job != nil || runner != nil { Log.write("quit: stopping what runs") }
        job?.killNow()
        runner?.killNow()
        statsWindow?.stop()      // fs_usage, if it runs
        setupWindow?.stop()
        settingsWindow?.stop()
        activeAdmin?.killNow()   // a password dialog still up goes with the app
        // A stop sudo refused while starting (it runs as root for a moment) must land before the app goes, or
        // fs_usage could start with no one left to stop it: wait for it (sudo's own limit ends it at the latest).
        guard ProgramTrace.finishStopping() else { return .terminateNow }
        Log.write("quit: waiting for sudo to accept the stop")
        let deadline = ProgramTrace.clock + TimeInterval(SudoRule.sudoTimeout)
        // A run-loop timer in the common modes: AppKit waits for the reply in a nested run loop, possibly inside a
        // main-queue block (the SIGTERM handler), where queued main-queue work wouldn't run but timers do.
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !ProgramTrace.finishStopping() || ProgramTrace.clock >= deadline else { return }
                timer.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// The volume list comes from ssd-resume, so the app and the scripts can't disagree. It runs as a job
    /// (off the main thread, with a time limit), and only if the scripts speak the app's protocol.
    private func loadVolumes() {
        for script in [Paths.resume, Paths.off] {
            guard FileManager.default.isExecutableFile(atPath: script) else {
                return configFailed("\(Paths.tilde(script)) is missing")
            }
            guard Paths.speaksProtocol(script) else {
                return configFailed("\(Paths.tilde(script)) is too old: run scripts/install.sh from the SSD Monitor repo (it installs helpers/)")
            }
        }
        // The job keeps itself alive until the command exits.
        Job(Paths.resume, ["--step", "list"], label: "ssd-resume --step list", timeout: 15) { [weak self] r in
            self?.volumesLoaded(r)
        }.start()
    }

    private func volumesLoaded(_ r: JobResult) {
        guard r.ok else {
            return configFailed(r.timedOut ? "ssd-resume --step list took too long" : "ssd-resume --step list failed (exit \(r.status))")
        }
        let list = r.lines("VOLUME").map { f in
            f.count == 3 && f.allSatisfy { !$0.isEmpty } ? Volume(name: f[0], uuid: f[1], path: f[2]) : nil
        }
        // All or nothing: a volume the app doesn't know about could be missing without anyone noticing.
        guard !list.isEmpty, !list.contains(where: { $0 == nil }) else {
            return configFailed("ssd-resume --step list gave no volumes, or a malformed line")
        }
        let valid = list.compactMap { $0 }
        guard Set(valid.map(\.name)).count == valid.count, Set(valid.map { $0.uuid.uppercased() }).count == valid.count,
              Set(valid.map(\.path)).count == valid.count else {
            return configFailed("ssd-resume --step list has a volume twice")
        }
        volumes = valid
        Log.write("watching \(volumes.map(\.name).joined(separator: ", "))")
        let watcher = DiskWatcher(uuids: Set(volumes.map(\.uuid)))
        watcher.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.statsWindow?.checkDevices()   // only compares; rebuilds only if the SSD's own disks changed
                self?.scheduleEvaluate()
            }
        }
        self.watcher = watcher
        watcher.start()
        watchMarkerFolder()
        onMain(after: 1) { [weak self] in self?.evaluate() }   // after DiskArbitration listed the disks
    }

    /// `ssd-off` writes its planned-unplug marker into ~/Local/ssd, and removes it if it fails: a change in
    /// that folder is looked at right away. (A vnode watch: no cost while nothing changes.)
    private func watchMarkerFolder() {
        let folder = (Paths.plannedMarker as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let fd = open(folder, O_EVTONLY)
        guard fd >= 0 else { Log.write("can't watch \(Paths.tilde(folder))"); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleEvaluate() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        markerWatch = source
    }

    private func configFailed(_ message: String) {
        configError = message
        Log.write(message)
        statusMenu?.refresh()
    }

    /// Keeps when the SSD was plugged in (for Statistics' "since plugged in"). Only on a change between attached
    /// and not: one registry lookup per plug-in.
    private func noteAttachment(connected: Bool, replugged: Bool) {
        let first = !attachmentChecked
        attachmentChecked = true
        let starting = AppController.uptime - launchedAt < AppController.startupGrace
        // Gone and back between two looks (the watcher latched it): a sure absence, and a new attachment.
        if replugged {
            sawSSDAbsent = true
            if connected { ssdAttachment = nil }
        }
        guard connected else {
            // An absence while the app is still starting may only mean DiskArbitration hasn't listed the SSD yet.
            if first { firstLookAbsent = true } else if !starting || replugged { sawSSDAbsent = true }
            ssdAttachment = nil
            return
        }
        guard ssdAttachment == nil else { return }
        // Seen arriving: after a sure absence, or after an absent first look once the start-up time had passed
        // when DiskArbitration listed it (not when this look happened).
        let arrival = watcher?.arrivedAt
        let listedWhileStarting = arrival.map { $0.uptime - launchedAt < AppController.startupGrace } ?? starting
        let arrived = sawSSDAbsent || (firstLookAbsent && !listedWhileStarting)
        attachmentGeneration = watcher?.connections ?? 0
        let id = ssdDevices().volumes.first.flatMap { DiskCounters.diskEntryID(volumeBSD: $0.bsd) }
        ssdAttachment = (id, arrived ? arrival?.wall ?? Date() : nil)
        resolveAttachment()
    }

    /// With the disk's ID known: a time saved for this very attachment (an earlier run of the app saw it arrive)
    /// wins, and a time seen now is saved. Never replaces a saved one.
    private func resolveAttachment() {
        guard let attachment = ssdAttachment, let id = attachment.id else { return }
        if let saved = Preferences.attachmentTime(id: id) {
            ssdAttachment = (id, saved)
        } else if let at = attachment.at {
            Preferences.saveAttachment(id: id, at: at)
        }
    }

    /// The attachment as Statistics needs it. If the disk's ID couldn't be read when it arrived, it is looked up
    /// again now, but only while it is still the same plug-in (the watcher's connection count hasn't moved).
    func currentAttachment() -> (id: UInt64?, at: Date?)? {
        guard let attachment = ssdAttachment, attachment.id == nil,
              watcher?.connections == attachmentGeneration else { return ssdAttachment?.id == nil ? nil : ssdAttachment }
        guard let id = ssdDevices().volumes.first.flatMap({ DiskCounters.diskEntryID(volumeBSD: $0.bsd) }) else {
            return nil
        }
        ssdAttachment = (id, attachment.at)
        resolveAttachment()
        return ssdAttachment
    }

    // MARK: - statistics, settings, the sudo rule

    var canOpenStatistics: Bool { configError == nil && !volumes.isEmpty }

    func openStatistics() {
        guard canOpenStatistics else { return }
        if let statsWindow { return statsWindow.show() }
        let window = StatsWindow(controller: self, volumes: volumes)
        window.onClose = { [weak self] in self?.statsWindow = nil }
        statsWindow = window
        window.show()
    }

    func openSettings() {
        if let settingsWindow { return settingsWindow.show() }
        let window = SettingsWindow(controller: self)
        window.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = window
        window.show()
    }

    /// The setup for the sudo rule. As the welcome screen it is shown once: whatever closes it counts as the
    /// answer, so it doesn't come back by itself.
    func showSudoSetup(welcome: Bool) {
        if let setupWindow { return setupWindow.show() }
        let window = SetupWindow(controller: self, welcome: welcome)
        window.onClose = { [weak self] in
            if welcome { Preferences.welcomeAnswered = true }
            self?.setupWindow = nil
        }
        setupWindow = window
        window.show()
    }

    /// The welcome screen, at the first launch without the sudo rule (one file check; nothing else at launch).
    private func showWelcomeOnce() {
        guard !Preferences.welcomeAnswered else { return }
        if SudoRule.isInstalled {
            Preferences.welcomeAnswered = true
        } else {
            Log.write("welcome screen (no sudo rule)")
            showSudoSetup(welcome: true)
        }
    }

    /// The rule file may have changed (a change through the password dialog has ended): what was known about
    /// whether sudo accepts it no longer holds.
    func sudoRuleFileChanged() {
        sudoRuleWorks = nil
        sudoRuleRefusal = nil
        setupWindow?.ruleChanged()
        sudoRuleChanged()
    }

    /// Bring Settings and Statistics up to date with the rule (Statistics waits while the setup checks it).
    func sudoRuleChanged() {
        guard !quitting else { return }
        settingsWindow?.refresh()
        if !sudoRuleVerifying { statsWindow?.sudoRuleChanged() }
    }

    /// A trace started through the rule (true) or sudo wanted a password (false).
    func sudoRuleTried(works: Bool, refusal: String? = nil) {
        guard sudoRuleWorks != works || sudoRuleRefusal != refusal else { return }
        sudoRuleWorks = works
        sudoRuleRefusal = works ? nil : refusal
        settingsWindow?.refresh()
    }

    /// One change to the rule at a time (adding it includes the check that follows).
    var sudoRuleChanging: Bool { adminTasks > 0 || sudoRuleVerifying }

    @objc func openSettingsAction(_ sender: Any?) { openSettings() }

    /// nil while another change to the rule is still going.
    func addSudoRule(_ completion: @escaping @MainActor (SudoRule.Outcome) -> Void) -> AdminTask? {
        runAdmin(SudoRule.installScript(), prompt: SudoRule.installPrompt, label: "add the sudo rule", completion)
    }

    func removeSudoRule(_ completion: @escaping @MainActor (SudoRule.Outcome) -> Void) -> AdminTask? {
        guard !sudoRuleVerifying else { return nil }   // not while the setup is adding and checking it
        return runAdmin(SudoRule.removeScript(), prompt: SudoRule.removePrompt, label: "remove the sudo rule", completion)
    }

    /// The password dialog may come up under the alarm's screen: the screen steps aside while it is up, as it
    /// does for the scripts' dialogs. Whatever the window that asked does meanwhile (it may close), the rule is
    /// looked at again once the change has ended.
    private func runAdmin(_ shell: String, prompt: String, label: String,
                          _ completion: @escaping @MainActor (SudoRule.Outcome) -> Void) -> AdminTask? {
        guard adminTasks == 0 else { return nil }
        adminTasks += 1
        if adminTasks == 1 { adminPasswordWatch.start() }
        let before = SudoRule.signature()
        let task = AdminTask(shell: shell, prompt: prompt, label: label, onExit: { [weak self] outcome in
            guard let self else { return }
            self.adminTasks -= 1
            self.activeAdmin = nil
            if self.adminTasks == 0 { self.adminPasswordWatch.stop() }
            // What was known about the rule goes only if the file changed (a cancelled or failed change leaves it
            // as it was; one that went through counts even if its osascript was stopped before it could say so).
            if outcome == .done { SudoRule.lastChange = label == "add the sudo rule" }   // for a folder it can't look into
            if outcome == .done || SudoRule.signature() != before { self.sudoRuleFileChanged() } else { self.sudoRuleChanged() }
        }, completion: completion)
        activeAdmin = task
        return task
    }

    /// The setup's volumes that are attached now, with their BSD names and where they are mounted (from
    /// DiskArbitration's records), and how many times the SSD's disks came or went so far.
    func ssdDevices() -> (volumes: [(name: String, bsd: String, mountedAt: String?)], attachments: Int) {
        guard let watcher else { return ([], 0) }
        let list = volumes.compactMap { volume in
            watcher.disk(uuid: volume.uuid).map { (volume.name, $0.bsdName, $0.volumePath) }
        }
        return (list, watcher.attachments)
    }

    // MARK: - evaluate

    func scheduleEvaluate() {
        // Events are handled together, 0.3 s later. A moment of full health in between must still end a
        // problem's 3-second clock, so two short outages never add up to an alarm: checked right away (one
        // cached mount-table read).
        if problemSince != nil, currentHealth().allOK { problemSince = nil }
        guard !evaluatePending else { return }
        evaluatePending = true
        onMain(after: 0.3) { [weak self] in
            self?.evaluatePending = false
            self?.evaluate()
        }
    }

    /// One evaluation after `delay`, not one per disk event: the earliest deadline wins (a later pending check
    /// is replaced), and each check schedules whatever comes next. Healthy state cancels it.
    private func checkAgain(after delay: TimeInterval) {
        let due = AppController.uptime + max(0, delay)
        if let pendingCheck, pendingCheck.due <= due { return }
        cancelCheck()
        // A timer source, not asyncAfter: cancelling it really removes it (nothing fires later).
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, delay) + 0.1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.cancelCheck()
                self?.evaluate()
            }
        }
        timer.resume()
        pendingCheck = (timer, due)
    }

    private func cancelCheck() {
        pendingCheck?.timer.cancel()
        pendingCheck = nil
    }

    /// Opening the menu re-checks everything (and is the only time free space is read while healthy).
    func refreshForMenu() { evaluate() }

    /// The SSD's state right now: one read of the kernel's cached mount table, no disk access.
    @discardableResult
    private func currentHealth() -> Health {
        if let watcher { health = Health.evaluate(volumes, watcher) }
        return health
    }

    private func evaluate() {
        guard let watcher, configError == nil else { statusMenu?.refresh(); return }
        let h = currentHealth()
        defer { updateSnoozeTimer(); statusMenu?.refresh() }

        // Remember that the SSD was gone, whatever is on screen: its return starts the resume. The watcher
        // latches a disconnect that is already over by now. (At login the SSD may simply not be attached
        // yet; that counts only after the startup grace.)
        let now = AppController.uptime
        let lostAll = watcher.takeAllGone()
        if lostAll || (!h.connected && (seenConnected || now - launchedAt >= AppController.startupGrace)) {
            wasDisconnected = true
        }
        // First sight of the SSD since the app started, and a marker says it was ejected: it came back while the
        // app was not running. That return is owed its resume too.
        if h.connected, !seenConnected, markerSaysEjected() { wasDisconnected = true }
        if h.connected { seenConnected = true; plannedAway = false }
        noteAttachment(connected: h.connected, replugged: lostAll)

        switch phase {
        case .resuming:
            if let started = resumeStartedAt, let date = markerDate(), date > started {
                // ssd-off was started during the resume: the unplug wins. Its services stay owed: if ssd-off
                // stops halfway, the resume runs once it is gone; if the SSD goes away, its return runs a full one.
                Log.write("ssd-off started during the resume; the resume stops")
                runner?.cancel()
                runner = nil
                alarmed.formUnion(owedScope)
                overlay.close()
                phase = .idle   // looks again right away (see `phase`): planned from here
            } else if !h.connected {
                abortResume()
            } else if lostAll {   // gone and back already: what the resume did so far may be stale
                autoResume(volumes.map(\.name), because: "The SSD was gone for a moment during the resume")
            } else if let runner, runner.step != .volumes, !h.allOK {
                // A volume dropped out after the wait for the volumes. Like any problem, it counts once it lasts
                // 3 s: then the resume starts over, with its services too.
                guard let since = problemSince else {
                    problemSince = now
                    checkAgain(after: AppController.debounce)
                    return
                }
                guard now - since >= AppController.debounce else {
                    checkAgain(after: AppController.debounce - (now - since))
                    return
                }
                let dropped = h.bad.map(\.volume.name)
                autoResume(Set(owedScope).union(dropped).sorted(),
                           because: "\(dropped.joined(separator: ", ")) dropped out during the resume")
            } else {
                if h.allOK {
                    problemSince = nil
                    if let summary = pendingSuccess {   // the volume that dropped out at the end is back
                        resumeDone(.success(summary))
                        return
                    }
                }
                runner?.healthChanged(h)   // the snapshot just read: no second read
            }
            return
        case .busy:
            // A volume missing while a button's command runs (a Remount, say) gets its services restarted by the
            // resume that follows, even if it is back by then.
            if h.connected { alarmed.formUnion(h.bad.map(\.volume.name)) }
            return
        case .idle, .alarm, .asking:
            break
        }

        // The SSD is back after being gone (planned or not): resume while its volumes come in.
        if wasDisconnected, h.connected {
            autoResume(volumes.map(\.name), because: "The SSD is back")
            return
        }
        if h.allOK {
            problemSince = nil
            // A stopped resume whose missing volumes are back: start it over, with their services too (they
            // may have dropped out after their services were restarted).
            if phase == .asking, failedStep != nil, !askingCovers.isEmpty {
                autoResume(Set(owedScope).union(askingCovers).sorted(), because: "The missing volumes are back")
                return
            }
            guard phase != .asking else { return }   // let the user read and answer it
            waitingForReplug = false                  // all in place and nothing in progress: no unplug coming
            dismissed = nil                           // that problem is over; a new one alarms again
            if !alarmed.isEmpty {                     // fixed in place, e.g. mounted again by hand
                cancelCheck()
                autoResume(alarmed.sorted(), because: "The volumes are back in place")
                return
            }
            cancelCheck()                             // nothing to time while healthy
            if phase == .alarm {                      // opened from the menu before it counted as a problem
                sound.stop()
                overlay.close()
                phase = .idle
            }
            clearForgottenMarker()
            return
        }

        // The SSD away during a grace period: look again when it ends, whatever follows (planned or not), so
        // the menu bar turns red then. Until the SSD was first seen, the end of the login grace counts too (a
        // wake meanwhile has its own). The earliest one still ahead; that check schedules the next.
        var graceEnds = [graceUntil]
        if !seenConnected { graceEnds.append(launchedAt + AppController.startupGrace) }
        if !h.connected, let next = graceEnds.filter({ $0 > now }).min() { checkAgain(after: next - now) }

        if isPlanned(h) {
            // Whatever goes unmounted on the way is owed a resume, in case the unplug stops halfway. (If the SSD
            // goes away, its return runs a full one anyway.)
            if h.connected { alarmed.formUnion(h.bad.map(\.volume.name)) }
            // The eject's "Safe to unplug" follows the mode: with the snooze row while it is on, OK while it isn't.
            if phase == .asking, askingIsSafeToUnplug, safeToUnplugRequires != requireActive { showSafeToUnplug() }
            guard requireActive, phase != .asking else {
                problemSince = nil
                if phase == .alarm { sound.stop(); overlay.close(); phase = .idle }
                return
            }
            // "Require the SSD": planned or not, whatever isn't in place gets its screen, silent (on purpose), until
            // the SSD is back or the user snoozes it. Like any problem it first comes up after the grace periods
            // (login, wake) and 3 s; one already up stays. Not over a screen waiting for the user (the eject's
            // "Safe to unplug" offers the snooze itself).
            if phase == .alarm { sound.stop(); problemSince = nil; showAlarm(sound: false); return }
            let graceEnd = max(graceUntil, seenConnected ? 0 : launchedAt + AppController.startupGrace)
            if now < graceEnd { problemSince = nil; checkAgain(after: graceEnd - now); return }
            guard let since = problemSince else {
                problemSince = now
                checkAgain(after: AppController.debounce)
                return
            }
            guard now - since >= AppController.debounce else {
                checkAgain(after: AppController.debounce - (now - since))
                return
            }
            problemSince = nil
            showAlarm(sound: false)
            return
        }
        let bad = Set(h.bad.map(\.volume.name))
        // Quiet: a dismissed problem (unless it gets worse), or one that was already there when a screen waiting
        // for the user came up (that screen stays). No alarm for it, but it is still timed once, silently, so its
        // volumes get the resume when they are back; after that the app stays idle. While "Require the SSD" is on,
        // a dismissed problem isn't quiet: its screen comes back (silently), and only a snooze ends it.
        let wasDismissed = dismissed.map { bad.isSubset(of: $0.bad) && (h.connected || !$0.connected) } == true
        let quiet = (phase == .idle && wasDismissed && !requireActive)
            || (phase == .asking && h.connected && bad.isSubset(of: askingCovers))
        if quiet, bad.isSubset(of: alarmed) {
            problemSince = nil
            return
        }
        if now < graceUntil {
            checkAgain(after: graceUntil - now)
            return
        }
        guard let since = problemSince else {
            problemSince = now
            checkAgain(after: AppController.debounce)
            return
        }
        guard now - since >= AppController.debounce else {
            checkAgain(after: AppController.debounce - (now - since))
            return
        }

        alarmed.formUnion(bad)
        if quiet { problemSince = nil; return }                   // recorded for the resume; no alarm
        if phase == .alarm { showAlarm(sound: false); return }   // keep the shown alarm current (only if it changed)
        showAlarm(sound: !wasDismissed)                           // the user has heard about this one already
    }

    /// Is the SSD going away on purpose? The app's own eject, or `ssd-off`'s marker, read each time (ssd-off
    /// removes it when it fails). A marker counts while it is less than 10 minutes old. The unplug is confirmed
    /// when the SSD goes away within that time, or when the marker says "ejected" (written after a successful
    /// eject, so it also holds after an app restart while the SSD is away): then no alarm until the SSD is back,
    /// and its return starts the resume. Any other marker is a leftover (ssd-off killed halfway) and is removed.
    private func isPlanned(_ h: Health) -> Bool {
        if waitingForReplug { return true }
        guard let date = markerDate() else { plannedAway = false; return false }
        let age = Date().timeIntervalSince(date)
        let fresh = age <= AppController.markerLifetime
        if !h.connected, fresh || markerSaysEjected() {
            plannedAway = true
            wasDisconnected = true   // the marker proves the unplug, even within the startup grace
        }
        if plannedAway && !h.connected { return true }
        if fresh {
            // Not confirmed yet (the SSD is still here): look again when the marker runs out, in case
            // ssd-off was killed halfway and nothing else happens.
            checkAgain(after: AppController.markerLifetime - age)
            return true
        }
        try? FileManager.default.removeItem(atPath: Paths.plannedMarker)
        Log.write("ignored a stale planned-unplug marker")
        return false
    }

    private func markerDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.plannedMarker))?[.modificationDate] as? Date
    }

    /// The marker says the eject happened (ssd-off or the app wrote "ejected" after a successful eject).
    private func markerSaysEjected() -> Bool {
        (try? String(contentsOfFile: Paths.plannedMarker, encoding: .utf8))?.contains("ejected") == true
    }

    /// A planned-unplug marker that nobody cleared (the SSD never went away): drop it once it has run out.
    private func clearForgottenMarker() {
        guard let date = markerDate(), Date().timeIntervalSince(date) > AppController.markerLifetime else { return }
        try? FileManager.default.removeItem(atPath: Paths.plannedMarker)
        Log.write("removed a forgotten planned-unplug marker")
    }

    private func clearIncident() {
        autoStarts = 0
        alarmed = []
        unmountedByApp = []
        wasDisconnected = false
        waitingForReplug = false
        dismissed = nil
        problemSince = nil
        remounted = []
        alarmNote = []
        lastBusy = []
        lastBusyWhy = []
        // Only a marker from before the resume: one that ssd-off wrote since is a new unplug request.
        if let date = markerDate(), date <= (resumeStartedAt ?? Date()) {
            try? FileManager.default.removeItem(atPath: Paths.plannedMarker)
        }
    }

    // MARK: - screens

    /// A command runs for a button: the screen can't be answered meanwhile.
    private func working(_ content: OverlayContent) {
        phase = .busy
        overlay.show(content)
        statusMenu?.refresh()
    }

    /// A screen that waits for the user. Problems already there don't replace it; new ones do.
    private func ask(_ content: OverlayContent) {
        phase = .asking
        failedStep = nil
        askingIsSafeToUnplug = false
        askingCovers = Set(currentHealth().bad.map(\.volume.name))
        overlay.show(content)
        statusMenu?.refresh()
    }

    // MARK: - alarm

    func showAlarm(sound playSound: Bool) {
        if let runner {   // a stopped resume whose screen this replaces: its services are still owed
            runner.cancel()
            alarmed.formUnion(owedScope)
            self.runner = nil
        }
        let alreadyShown = phase == .alarm && overlay.isShown
        phase = .alarm
        let h = health
        var content: OverlayContent
        if !h.connected, waitingForReplug || plannedAway {
            content = OverlayContent(
                tone: .info, title: "SSD not connected",
                message: "The SSD was ejected. Plug it back in (directly into the Mac, not a hub): the resume starts "
                    + "by itself as soon as it is back.")
        } else if !h.connected {
            content = OverlayContent(
                tone: .alarm, title: "SSD disconnected",
                message: "None of the SSD's volumes are attached. Check the cable and plug the SSD back in "
                    + "(directly into the Mac, not a hub). The resume starts by itself as soon as it is back.")
        } else {
            let fixable = h.bad.contains { if case .notMounted = $0.state { return true }; if case .elsewhere = $0.state { return true }; return false }
            let readOnly = h.bad.contains { $0.state == .readOnly }
            content = OverlayContent(
                tone: .alarm, title: "SSD problem: \(h.bad.count) of \(h.volumes.count) volumes not in place",
                message: readOnly && !fixable
                    ? "macOS mounted a volume read-only, usually after finding a problem on the disk. Run First Aid in Disk Utility, or unmount the rest and replug the SSD."
                    : "Check the SSD. Try Remount first. If that doesn't help, unmount the rest, then unplug the SSD and plug it back in.")
            if fixable { content.buttons.append(OverlayButton("Remount", .primary) { [weak self] in self?.remount() }) }
            content.buttons.append(OverlayButton("Unmount the rest") { [weak self] in self?.unmountRest(planned: false) })
        }
        // "Require the SSD" on: no Dismiss. The screen stays until the SSD is back, or a snooze (which then
        // dismisses it the same way).
        if requireActive {
            content.message += " This Mac needs the SSD: this screen stays until it is back. To use the Mac without it, snooze “Require the SSD”."
            content.snoozeLabel = "Snooze “Require the SSD”:"
            content.snoozeButtons = snoozeButtons { [weak self] in self?.dismissAlarm() }
        } else {
            content.buttons.append(OverlayButton("Dismiss") { [weak self] in self?.dismissAlarm() })
        }
        content.details = volumeLines(h) + (alarmNote.isEmpty ? [] : [""] + alarmNote)
        // The alarm on screen already says this (an unrelated event or opening the menu): leave it as it is.
        let key = ([content.title, content.message] + content.details + content.buttons.map(\.title)
                   + content.snoozeButtons.map(\.title)).joined(separator: "\n")
        if alreadyShown, !playSound, key == shownAlarmKey { statusMenu?.refresh(); return }
        shownAlarmKey = key
        overlay.show(content)
        if playSound {
            Log.write("alarm: \(h.connected ? h.issueKey : "SSD disconnected")")
            sound.play()
        }
        statusMenu?.refresh()
    }

    private func dismissAlarm() {
        sound.stop()
        let bad = Set(health.bad.map(\.volume.name))
        dismissed = (bad, health.connected)
        alarmNote = []
        overlay.close()
        phase = .idle
        // An alert opened from the menu before the problem counted keeps its 3-second clock: once it has
        // lasted that long, it is recorded (silently) so its volumes get the resume when they are back.
        if bad.isSubset(of: alarmed) { problemSince = nil }
        autoStarts = 0   // the user has seen it
        Log.write("alarm dismissed")
        statusMenu?.refresh()
    }

    // MARK: - require the SSD

    /// On by default: while the SSD isn't fully in place, its screen stays up until the SSD is back or the user
    /// snoozes this. Read each time (a snooze that has run out counts as on).
    var requireActive: Bool { Preferences.requireSSD }

    /// The snooze row for a screen: each choice snoozes, then `then` closes that screen.
    private func snoozeButtons(then: @escaping () -> Void) -> [OverlayButton] {
        AppController.snoozeChoices.map { choice in
            OverlayButton(choice.short) { [weak self] in
                self?.snoozeRequire(for: choice.seconds)
                then()
            }
        }
    }

    /// Snooze for this long (nil: off until turned back on). It comes back by itself when the time is up.
    func snoozeRequire(for seconds: TimeInterval?) {
        Preferences.requireSnoozedUntil = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        Log.write(seconds.map { "Require the SSD: snoozed for \(Int($0 / 60)) min" } ?? "Require the SSD: off until turned back on")
        updateSnoozeTimer()
        statusMenu?.refresh()
    }

    /// The menu's snooze: also closes the screen that "Require the SSD" kept up, like its own snooze buttons.
    func snoozeFromMenu(for seconds: TimeInterval?) {
        let wasActive = requireActive
        snoozeRequire(for: seconds)
        guard wasActive else { return }
        if phase == .alarm { dismissAlarm() } else if phase == .asking, askingIsSafeToUnplug { closeResult() }
    }

    func turnRequireOn() {
        Preferences.requireSnoozedUntil = nil
        Log.write("Require the SSD: on")
        updateSnoozeTimer()
        scheduleEvaluate()   // the SSD may be missing right now: its screen comes up
    }

    /// The snooze's end needs a timer only while the SSD isn't fully in place: then one timer, set for that end
    /// (wall-clock time, so time asleep counts; a wake looks again anyway). While healthy there is none, as
    /// everywhere else: the setting is read each time, and a snooze that has run out counts as on. When it ends,
    /// the mode is on again without a word; if the SSD is still missing, its screen comes up. Called after every
    /// evaluation and every change of the setting.
    private func updateSnoozeTimer() {
        if let until = Preferences.requireSnoozedUntil, until <= Date() {
            Preferences.requireSnoozedUntil = nil
            Log.write("Require the SSD: on again (snooze ended)")
        }
        let until = Preferences.requireSnoozedUntil
        let target = until != nil && until != .distantFuture && watcher != nil && configError == nil && !health.allOK
            ? until : nil
        guard target != snoozeTimerFor else { return }
        snoozeTimer?.cancel()
        snoozeTimer = nil
        snoozeTimerFor = target
        guard let target else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(0, target.timeIntervalSinceNow) + 0.5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snoozeTimer?.cancel()
                self.snoozeTimer = nil
                self.snoozeTimerFor = nil
                self.evaluate()   // the snooze has run out: on again (updateSnoozeTimer logs it), screen if needed
            }
        }
        timer.resume()
        snoozeTimer = timer
    }

    private func volumeLines(_ h: Health) -> [String] {
        let width = (h.volumes.map(\.volume.name.count).max() ?? 8) + 2
        return h.volumes.map { s in
            let name = s.volume.name.padding(toLength: width, withPad: " ", startingAt: 0)
            switch s.state {
            case .ok: return "✓ \(name)\(Paths.tilde(s.volume.path))"
            case .readOnly: return "! \(name)read-only at \(Paths.tilde(s.volume.path))"
            case .elsewhere(let path): return "! \(name)mounted at \(Paths.tilde(path)), should be \(Paths.tilde(s.volume.path))"
            case .notMounted: return "✗ \(name)not mounted (\(Paths.tilde(s.volume.path)))"
            case .absent: return "✗ \(name)not attached"
            }
        }
    }

    // MARK: - remount

    private func remount() {
        let before = health.bad.map(\.volume.name)
        sound.stop()
        alarmNote = []
        alarmed.formUnion(before)
        working(OverlayContent(tone: .progress, title: "Remounting",
                               message: "Mounting \(before.joined(separator: ", ")) at \(before.count == 1 ? "its path" : "their paths")…",
                               progress: -1, progressLabel: "diskutil mount"))
        run(Paths.resume, ["--step", "mounts"], timeout: 60) { [weak self] r in
            guard let self else { return }
            // Everything the command mounted gets its services restarted, also a volume that dropped out
            // while it ran.
            self.alarmed.formUnion(r.lines("MOUNTED").compactMap(\.first))
            // Judged by the kernel's mount table: every volume at its path and writable.
            let h = self.currentHealth()
            if h.allOK {
                Log.write("remount worked: \(before.joined(separator: ", "))")
                self.remounted = before
                self.autoStarts = 0   // the user asked for it
                self.autoResume(self.alarmed.sorted(), because: "Remount worked")
            } else {
                Log.write("remount did not work")
                var note = ["Remount didn't work:"]
                if r.timedOut { note.append("  the mount command took longer than 60 s and was stopped") }
                note += r.lines("FAILED").map { "  \($0.first ?? ""): \($0.dropFirst().joined(separator: " "))" }
                if note.count == 1 { note += h.bad.map { "  \($0.volume.name): \($0.state.short)" } }
                self.alarmNote = note
                self.showAlarm(sound: false)
            }
        }
    }

    // MARK: - unmount the rest / eject

    func confirmEject() {
        guard canEject else { return }   // the menu may have been open while the state changed
        var content = OverlayContent(
            tone: .info, title: "Eject the SSD?",
            message: "Use this before unplugging the SSD on purpose. There is no alarm while it is away, "
                + "and the resume runs by itself when you plug it back in.")
        content.buttons = [
            OverlayButton("Eject", .primary) { [weak self] in self?.unmountRest(planned: true) },
            OverlayButton("Cancel") { [weak self] in self?.closeResult() },
        ]
        ask(content)
    }

    private func unmountRest(planned: Bool) {
        sound.stop()
        alarmNote = []
        waitingForReplug = true
        if planned {   // survives an app restart while the SSD is away; the resume removes it
            try? Data("\(Int(Date().timeIntervalSince1970))\n".utf8).write(to: URL(fileURLWithPath: Paths.plannedMarker))
        }
        working(OverlayContent(tone: planned ? .info : .progress, title: "Unmounting the SSD",
                               message: "Unmounting its volumes…", progress: -1, progressLabel: "diskutil unmount"))
        run(Paths.off, ["--step", "unmount"], timeout: 90) { [weak self] r in
            guard let self else { return }
            self.unmountedByApp.formUnion(r.lines("UNMOUNTED").compactMap(\.first))
            if r.ok {
                self.eject(planned: planned)
            } else {
                self.lastBusy = r.lines("BUSY").compactMap(\.first)
                self.lastBusyWhy = r.lines("BUSY").map { "diskutil: " + $0.joined(separator: ": ") }
                self.showUsers(planned: planned, note: r.timedOut ? "diskutil did not finish within 90 seconds and was stopped." : nil)
            }
        }
    }

    /// Unmount failed (or hung): list what has files open on the SSD, with Try again and Force unmount.
    private func showUsers(planned: Bool, note: String? = nil) {
        working(OverlayContent(tone: planned ? .info : .progress, title: "Checking what uses the SSD",
                               progress: -1, progressLabel: "lsof"))
        run(Paths.off, ["--step", "users"], timeout: 45) { [weak self] r in
            guard let self else { return }
            let users = AppController.userLines(r)
            let apps = AppController.appsWarning(r.lines("APP").compactMap(\.first))
            let stillMounted = self.lastBusy.isEmpty
                ? "Some volumes are still mounted." : "Still mounted: \(self.lastBusy.joined(separator: ", "))."
            var content = OverlayContent(
                tone: planned ? .info : .alarm, title: "Can't unmount: the SSD is in use",
                message: (note.map { $0 + " " } ?? "") + stillMounted
                    + " Quit the programs that have files open there, then press Force unmount. Shells and agents"
                    + " that only have their working folder there lose nothing. If nothing is left, Try again unmounts normally.")
            let head = self.lastBusyWhy + (apps.map { [$0] } ?? [])
            if r.timedOut {
                content.details = head + ["(lsof took longer than 45 seconds and was stopped; the list may be incomplete)"] + users
            } else if !r.ok {
                let why = r.lines("FAILED").first?.joined(separator: " ") ?? "exit status \(r.status)"
                content.details = head + ["(could not list what uses the SSD: \(why))"]
            } else if !r.lines("WARN").isEmpty {
                content.details = head + ["(lsof reported errors; the list may be incomplete)"] + users
            } else {
                content.details = head
                    + (users.isEmpty ? ["(none of your programs has files open there. macOS services are not visible"
                                        + " to lsof without admin rights: diskutil's reason above names who refused)"] : users)
            }
            content.buttons = [
                OverlayButton("Try again", .primary) { [weak self] in self?.unmountRest(planned: planned) },
                OverlayButton("Force unmount…", .destructive) { [weak self] in
                    self?.confirmForce(planned: planned, users: users, apps: apps)
                },
                OverlayButton("Dismiss") { [weak self] in self?.cancelUnmount(planned: planned) },
            ]
            self.ask(content)
        }
    }

    /// The users step's lines, grouped by what to do about them: open files first (quit those programs), then
    /// macOS services, then programs that only have their working folder there (they lose nothing when forced).
    /// A program with both an open file and its working folder there is listed once, with the open file (the
    /// step lists open files before working folders, so its open-file line is never the one cut off).
    private static func userLines(_ r: JobResult) -> [String] {
        let rows = r.lines("USER")
        let withFiles = Set(rows.filter { $0.count >= 4 && $0[2] != "cwd" }.map { $0[1] })
        var files: [String] = [], system: [String] = [], cwd: [String] = [], other: [String] = []
        for f in rows {
            guard f.count >= 4 else { other.append(f.joined(separator: " ")); continue }
            let line = "  \(f[0]) (pid \(f[1])): \(Paths.tilde(f[3]))"
            switch f[2] {
            case "cwd": if !withFiles.contains(f[1]) { cwd.append(line) }
            case "system": system.append(line)
            default: files.append(line)
            }
        }
        var out: [String] = []
        if !files.isEmpty { out += ["Files open (quit these first, or they lose those files):"] + files }
        if !system.isEmpty { out += ["macOS services (they usually let go by themselves):"] + system }
        if !cwd.isEmpty { out += ["Only their working folder (they block a normal unmount, but lose nothing when forced):"] + cwd }
        return out + other
    }

    /// One line naming the open apps that may hold unsaved work (the users step's APP lines), or nil if none.
    private static func appsWarning(_ apps: [String]) -> String? {
        guard !apps.isEmpty else { return nil }
        let names = apps.count == 1 ? apps[0] : apps.dropLast().joined(separator: ", ") + " and " + apps[apps.count - 1]
        return "\(names) \(apps.count == 1 ? "is" : "are") open and may have unsaved work: save and quit \(apps.count == 1 ? "it" : "them") first."
    }

    private func confirmForce(planned: Bool, users: [String], apps: String?) {
        var content = OverlayContent(
            tone: .alarm, title: "Force unmount?",
            message: (apps.map { $0 + " " } ?? "")
                + "SSD Monitor first stops simulators, emulators, adb and Gradle, and flushes pending writes. "
                + "Programs with files open on the SSD then lose them, and unsaved work in them can be lost. "
                + "Shells and agents only show errors until the SSD is back.")
        content.details = users
        content.buttons = [
            OverlayButton("Force unmount", .destructive) { [weak self] in self?.forceUnmount(planned: planned) },
            OverlayButton("Back") { [weak self] in self?.showUsers(planned: planned) },
        ]
        ask(content)
    }

    /// ssd-off's force step, the same unmount as a terminal ssd-off: stop the dev services, flush, force-unmount.
    private func forceUnmount(planned: Bool) {
        working(OverlayContent(tone: .progress, title: "Forcing the unmount", progress: -1,
                               progressLabel: "stopping dev services, flushing, diskutil unmount force"))
        Log.write("force unmount")
        run(Paths.off, ["--step", "force"], timeout: 180) { [weak self] r in
            guard let self else { return }
            for s in r.lines("STOPPED") { Log.write("force unmount: " + s.joined(separator: " ")) }
            self.unmountedByApp.formUnion(r.lines("UNMOUNTED").compactMap(\.first))
            if r.ok {
                self.eject(planned: planned)
            } else {
                self.unmountProblem(planned: planned, title: "Force unmount failed",
                                    message: r.timedOut ? "The force unmount did not finish within 180 seconds and was stopped."
                                        : (r.lines("FAILED").first?.first ?? "Some volumes are still mounted."),
                                    details: r.lines("BUSY").map { "\($0.first ?? ""): \($0.dropFirst().joined(separator: " "))" },
                                    retry: { [weak self] in self?.forceUnmount(planned: planned) })
            }
        }
    }

    private func eject(planned: Bool) {
        working(OverlayContent(tone: planned ? .info : .progress, title: "Ejecting the SSD", progress: -1,
                               progressLabel: "diskutil eject"))
        run(Paths.off, ["--step", "eject"], timeout: 60) { [weak self] r in
            guard let self else { return }
            // "Safe to unplug" needs the app's own check to agree: nothing of the SSD in the mount table.
            if r.ok, self.currentHealth().anyMounted {
                Log.write("eject reported success, but a volume is still mounted")
                self.unmountProblem(planned: planned, title: "Eject failed",
                                    message: "The eject reported success, but a volume of the SSD is still mounted. Don't unplug yet.",
                                    details: self.volumeLines(self.health), retry: { [weak self] in self?.unmountRest(planned: planned) })
            } else if r.ok {
                Log.write("ejected")
                // A confirmed unplug: no alarm while the SSD is away, also after an app restart (see isPlanned).
                try? Data("\(Int(Date().timeIntervalSince1970))\nejected\n".utf8)
                    .write(to: URL(fileURLWithPath: Paths.plannedMarker))
                self.showSafeToUnplug()
            } else {
                self.unmountProblem(planned: planned, title: "Eject failed",
                                    message: r.timedOut ? "diskutil did not finish within 60 seconds and was stopped." : (r.lines("FAILED").first?.first ?? r.tail(1).first ?? ""),
                                    details: [], retry: { [weak self] in self?.eject(planned: planned) })
            }
        }
    }

    /// The eject's last screen. While "Require the SSD" is on it stays up like the alarm: only the SSD's return or
    /// a snooze ends it. Otherwise OK or a click closes it. Rebuilt if the mode changes while it is up (evaluate).
    private func showSafeToUnplug() {
        var content = OverlayContent(
            tone: .info, title: "Safe to unplug",
            message: "Unplug the SSD, wait 5 seconds, then plug it back in. The resume starts by itself as soon as it is back.")
        let require = requireActive
        if require {
            content.message += " This Mac needs the SSD: this screen stays until it is back. To use the Mac without it, snooze “Require the SSD”."
            content.snoozeLabel = "Snooze “Require the SSD”:"
            content.snoozeButtons = snoozeButtons { [weak self] in self?.closeResult() }
        } else {
            content.buttons = [OverlayButton("OK", .primary) { [weak self] in self?.closeResult() }]
            content.onClick = { [weak self] in self?.closeResult() }
        }
        ask(content)
        askingIsSafeToUnplug = true
        safeToUnplugRequires = require
    }

    private func unmountProblem(planned: Bool, title: String, message: String, details: [String], retry: @escaping () -> Void) {
        var content = OverlayContent(tone: planned ? .info : .alarm, title: title, message: message)
        content.details = details
        content.buttons = [
            OverlayButton("Try again", .primary, retry),
            OverlayButton("Dismiss") { [weak self] in self?.cancelUnmount(planned: planned) },
        ]
        ask(content)
    }

    /// The user stopped the unmount: whatever is left unmounted is a problem again, but no new sound for it.
    /// Everything this flow unmounted gets its services restarted when it is back (even if it is back already).
    private func cancelUnmount(planned: Bool) {
        waitingForReplug = false
        if planned { try? FileManager.default.removeItem(atPath: Paths.plannedMarker) }
        let h = currentHealth()
        let bad = Set(h.bad.map(\.volume.name))
        alarmed.formUnion(bad.union(unmountedByApp))
        unmountedByApp = []
        dismissed = (bad, h.connected)
        closeResult()
    }

    // MARK: - resume

    /// Menu actions check again: the menu may have been open while the state changed.
    func runResumeNow() {
        guard canResume else { return }
        autoStarts = 0   // the user asked for it
        autoResume(nil, because: "Run resume now")
    }

    func showAlarmFromMenu() {
        guard canShowAlarm else { return }
        showAlarm(sound: false)
    }

    private func startResume(serviceVolumes requested: [String]?) {
        // The whole SSD was gone at some point (even during a Remount): every service counts.
        let serviceVolumes = wasDisconnected ? volumes.map(\.name) : requested
        beginResume()
        let runner = makeRunner(serviceVolumes)
        lastStepShown = nil
        Log.write("resume start; services for: \(serviceVolumes?.joined(separator: ",") ?? "reconnect only")")
        runner.start(from: .volumes)
        showResumeProgress()
        statusMenu?.refresh()
    }

    /// Every resume run, new or again: the SSD is back, or the problem fixed. This disconnect, any planned unplug
    /// (its marker), and the problem's 3-second clock are over; a new problem during the run is timed from
    /// scratch, and only an ssd-off started from now on counts as a new unplug.
    private func beginResume() {
        pendingSuccess = nil
        cancelCheck()   // a pending grace or debounce check is moot now; the resume times its own
        sound.stop()
        wasDisconnected = false
        waitingForReplug = false
        plannedAway = false
        problemSince = nil
        unmountedByApp = []
        try? FileManager.default.removeItem(atPath: Paths.plannedMarker)
        resumeStartedAt = Date()
        phase = .resuming
    }

    /// A new resume for the services of these volumes, replacing any earlier one. Not started yet.
    @discardableResult
    private func makeRunner(_ serviceVolumes: [String]?) -> ResumeRunner {
        resumeScope = serviceVolumes
        runner?.cancel()
        let runner = ResumeRunner(serviceVolumes: serviceVolumes) { [weak self] in self?.currentHealth() ?? .empty }
        runner.onProgress = { [weak self] in self?.showResumeProgress() }
        runner.onPasswordDialog = { [weak self] visible in
            guard let self else { return }
            if visible { self.overlay.hide(for: "resume") } else { self.overlay.unhide(for: "resume") }
            self.statusMenu?.refresh()
        }
        runner.onDone = { [weak self] outcome in self?.resumeDone(outcome) }
        self.runner = runner
        return runner
    }

    /// The services still owed by the current (or stopped) resume. A manual resume's "only if reconnected"
    /// becomes every service here, to be safe.
    private var owedScope: [String] { resumeScope ?? volumes.map(\.name) }

    /// Every resume goes through here, whatever started it (the SSD back, volumes back, a drop-out during a
    /// resume, a stopped resume's volumes back, a button). One budget for all of them: at most 3 in a row until
    /// one finishes or the user acts (a button, Dismiss). Then it stops at the failure screen instead, so a
    /// loose cable can never keep the progress overlay up, or keep bringing it back.
    private func autoResume(_ serviceVolumes: [String]?, because reason: String) {
        // ssd-off is getting ready to unplug (a fresh marker, and the SSD has not gone away since): no resume
        // now, and nothing on screen. The services stay owed: the resume runs once ssd-off stops halfway (its
        // marker goes) or the marker runs out; if the SSD goes away, its return runs a full one.
        if !wasDisconnected, let date = markerDate(), Date().timeIntervalSince(date) <= AppController.markerLifetime {
            Log.write("\(reason); no resume while ssd-off gets ready to unplug")
            alarmed.formUnion(serviceVolumes ?? volumes.map(\.name))
            if phase != .idle || overlay.isShown {
                sound.stop()
                overlay.close()
                failedStep = nil
                phase = .idle
            }
            checkAgain(after: AppController.markerLifetime - Date().timeIntervalSince(date))
            return
        }
        guard autoStarts < AppController.maxAutoStarts else {
            Log.write("\(reason); not starting the resume again by itself (\(autoStarts) in a row)")
            wasDisconnected = false   // consumed: the user decides on the failure screen
            makeRunner(Set(serviceVolumes ?? volumes.map(\.name)).union(owedScope).sorted())
            resumeDone(.failure(step: .volumes,
                                reason: "The resume was interrupted \(autoStarts) times in a row (last: \(reason)). "
                                    + "Check the cable (directly into the Mac, not a hub), then press Resume again.",
                                output: volumeLines(currentHealth())))
            return
        }
        autoStarts += 1
        Log.write("\(reason); resume \(autoStarts) of at most \(AppController.maxAutoStarts) in a row")
        startResume(serviceVolumes: serviceVolumes)
    }

    private func showResumeProgress() {
        guard phase == .resuming, let runner else { return }
        if overlay.isShown, lastStepShown == runner.step {
            overlay.updateProgress(runner.fraction, label: runner.label)
            return
        }
        lastStepShown = runner.step
        var content = OverlayContent(tone: .progress, title: "Resuming the SSD",
                                     message: "Please don't use the Mac until this finishes.")
        content.details = runner.checklist
        content.progress = runner.fraction
        content.progressLabel = runner.label
        overlay.show(content)
    }

    private func abortResume() {
        Log.write("resume stopped: the SSD went away")
        pendingSuccess = nil
        runner?.cancel()
        runner = nil
        overlay.close()
        wasDisconnected = true   // its return starts the resume again (within the budget, see autoResume)
        phase = .idle   // looks again right away (see `phase`)
    }

    private func resumeDone(_ outcome: ResumeRunner.Outcome) {
        switch outcome {
        case .success(let summary):
            // A volume that dropped out at the very end: the success waits. Back within 3 s, it shows; if not,
            // the resume starts over with its services (see evaluate, .resuming).
            if !currentHealth().allOK {
                Log.write("resume done, but a volume is not in place; waiting up to 3 s")
                pendingSuccess = summary
                if problemSince == nil {
                    problemSince = AppController.uptime
                    checkAgain(after: AppController.debounce)
                }
                return
            }
            pendingSuccess = nil
            var lines: [String] = []
            if !remounted.isEmpty {
                lines.append("✓ Remount worked: " + remounted.map { name in
                    "\(name) is back at \(Paths.tilde(volumes.first { $0.name == name }?.path ?? ""))"
                }.joined(separator: "; "))
            }
            lines.append("✓ All \(volumes.count) volumes mounted at their paths")
            if !summary.mountedByApp.isEmpty { lines.append("✓ Mounted by SSD Monitor: \(summary.mountedByApp.joined(separator: ", "))") }
            lines += summary.restarted.map { "↻ \($0)" }
            let locks = summary.locksRemoved.count
            if locks > 0 { lines.append("✓ Removed \(locks) stale git lock file\(locks == 1 ? "" : "s")") }
            lines += summary.notes.map { "- \($0)" }
            if !summary.apps.isEmpty { lines.append("Reopen: \(summary.apps.joined(separator: ", "))") }
            if !summary.jobs.isEmpty { lines += ["May need a restart:"] + summary.jobs.map { "  \($0)" } }
            var content = OverlayContent(tone: .success, title: remounted.isEmpty ? "SSD is back" : "Remount worked",
                                         message: "Everything is in place. Rerun what failed.")
            content.details = lines
            content.buttons = [OverlayButton("Done", .primary) { [weak self] in self?.closeResult() }]
            content.onClick = { [weak self] in self?.closeResult() }
            clearIncident()
            runner = nil
            phase = .idle   // the incident is over; a new problem may replace this screen
            overlay.show(content)
        case .failure(let step, let reason, let output):
            var content = OverlayContent(tone: .failure, title: "Resume stopped at: \(step.title)", message: reason)
            content.details = output
            content.buttons = [
                OverlayButton("Resume again", .primary) { [weak self] in self?.continueResume(from: step) },
                OverlayButton("Start over") { [weak self] in self?.continueResume(from: .volumes) },
                OverlayButton("Dismiss") { [weak self] in self?.dismissFailure() },
            ]
            ask(content)
            failedStep = step
        }
        statusMenu?.refresh()
    }

    private func continueResume(from step: ResumeRunner.Step) {
        guard let runner else { return }
        failedStep = nil
        if wasDisconnected {   // the SSD was gone meanwhile: everything again, with every service
            autoStarts = 0
            autoResume(volumes.map(\.name), because: "Resume again, after the SSD was gone")
            return
        }
        Log.write("resume again from: \(step.title)")
        autoStarts = 1   // the user chose to go on: this run is the first of a new budget
        beginResume()
        lastStepShown = nil
        runner.start(from: step)
        showResumeProgress()
        statusMenu?.refresh()
    }

    /// The user stopped a failed resume. If volumes are still not in place, the resume is still owed (with its
    /// services): it runs by itself once they are back. The problem itself stays quiet unless it gets worse.
    private func dismissFailure() {
        runner?.cancel()
        runner = nil
        let h = currentHealth()
        let bad = Set(h.bad.map(\.volume.name))
        let scope = resumeScope
        clearIncident()
        if !bad.isEmpty {
            dismissed = (bad, h.connected)
            alarmed = bad.union(scope ?? volumes.map(\.name))
        }
        closeResult()
    }

    private func closeResult() {
        overlay.close()
        failedStep = nil
        askingIsSafeToUnplug = false
        phase = .idle
        statusMenu?.refresh()
        scheduleEvaluate()
    }

    // MARK: - commands

    /// Run one script step for the overlay's buttons. Stops counting toward the timeout while a password dialog is up.
    private func run(_ executable: String, _ args: [String], timeout: TimeInterval, completion: @escaping @MainActor (JobResult) -> Void) {
        var created: Job?
        let job = Job(executable, args, label: (executable as NSString).lastPathComponent + " " + args.joined(separator: " "),
                      timeout: timeout) { [weak self] r in
            guard let self, let created, self.job === created else { return }
            self.job = nil
            self.passwordWatch.stop()
            completion(r)
            self.statusMenu?.refresh()
        }
        created = job
        self.job = job
        passwordWatch.start()
        job.start()
        statusMenu?.refresh()
    }

    // MARK: - menu state

    var iconState: IconState {
        if configError != nil { return .error }
        let inGrace = AppController.uptime < graceUntil
        // The SSD unplugged is shown in red, planned or not, alarm dismissed or not, whatever runs (the user's
        // rule). Only in the first seconds after the app starts, while macOS may still be attaching it at
        // login, is it "waiting" (evaluate looks again when that grace ends). A wake doesn't count.
        let atLogin = !seenConnected && AppController.uptime - launchedAt < AppController.startupGrace
        if !health.connected { return atLogin ? .waiting : .issue }
        if phase == .resuming || phase == .busy { return .busy }
        if health.allOK { return .healthy }
        if waitingForReplug || plannedAway || inGrace { return .waiting }   // an eject still under way
        return .issue
    }

    /// macOS may nap the app while nothing happens; disk events still wake it. While a problem is being
    /// timed (the 3-second check) or a screen is up, it must not nap; while a resume or unmount runs, the
    /// Mac must not idle-sleep either. Screens that wait for the user, and dismissed problems, don't keep
    /// the Mac awake.
    private func updateActivity() {
        let options: ProcessInfo.ActivityOptions?
        switch phase {
        case .resuming, .busy: options = .userInitiated
        case .alarm, .asking: options = .userInitiatedAllowingIdleSystemSleep
        case .idle: options = problemSince != nil ? .userInitiatedAllowingIdleSystemSleep : nil
        }
        guard options != activityOptions else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = options.map { ProcessInfo.processInfo.beginActivity(options: $0, reason: "SSD incident") }
        activityOptions = options
    }

    func testSound() { sound.play() }
    func previewSound(_ name: String) { sound.play(times: 1, name: name) }

    var canShowAlarm: Bool { phase == .idle && !health.allOK && configError == nil }
    var canResume: Bool { phase == .idle && health.allOK }
    var canEject: Bool { phase == .idle && health.connected }
}
