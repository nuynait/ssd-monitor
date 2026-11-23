import AppKit

/// Run on the main queue after a delay, main-actor isolated.
func onMain(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
}

/// Decides what the SSD's state means and what to show:
/// - healthy: nothing on screen.
/// - a problem that lasts 3 s: the alarm overlay and sound, unless the SSD is going away on purpose.
/// - the SSD back after an unplug (or a problem fixed in place): the resume, with its progress overlay.
/// Everything is driven by disk events. While the SSD is healthy there is no timer at all.
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
                if visible { self.job?.pauseTimeout(); self.overlay.hide() } else { self.job?.resumeTimeout(); self.overlay.unhide() }
                self.statusMenu?.refresh()
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
        loadVolumes()
        statusMenu?.refresh()
    }

    /// Quitting while a command runs (the menu, or an update): stop it and everything it started first, so
    /// nothing keeps mounting or unmounting with nobody watching. Takes at most a third of a second.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if job != nil || runner != nil { Log.write("quit: stopping what runs") }
        job?.killNow()
        runner?.killNow()
        return .terminateNow
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
        watcher.onChange = { [weak self] in MainActor.assumeIsolated { self?.scheduleEvaluate() } }
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
        defer { statusMenu?.refresh() }

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
            if phase == .alarm { sound.stop(); overlay.close(); phase = .idle }
            // Whatever goes unmounted on the way is owed a resume, in case the unplug stops halfway. (If the SSD
            // goes away, its return runs a full one anyway.)
            if h.connected { alarmed.formUnion(h.bad.map(\.volume.name)) }
            problemSince = nil
            return
        }
        let bad = Set(h.bad.map(\.volume.name))
        // Quiet: a dismissed problem (unless it gets worse), or one that was already there when a screen waiting
        // for the user came up (that screen stays). No alarm for it, but it is still timed once, silently, so its
        // volumes get the resume when they are back; after that the app stays idle.
        let quiet = (phase == .idle && dismissed.map { bad.isSubset(of: $0.bad) && (h.connected || !$0.connected) } == true)
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
        showAlarm(sound: true)
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
        if !h.connected {
            content = OverlayContent(
                tone: .alarm, title: "SSD disconnected",
                message: "None of the SSD's volumes are attached. Check the cable and plug the SSD back in "
                    + "(directly into the Mac, not a hub). The resume starts by itself as soon as it is back.")
            content.buttons = [OverlayButton("Dismiss") { [weak self] in self?.dismissAlarm() }]
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
            content.buttons.append(OverlayButton("Dismiss") { [weak self] in self?.dismissAlarm() })
        }
        content.details = volumeLines(h) + (alarmNote.isEmpty ? [] : [""] + alarmNote)
        // The alarm on screen already says this (an unrelated event or opening the menu): leave it as it is.
        let key = ([content.title, content.message] + content.details + content.buttons.map(\.title)).joined(separator: "\n")
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
            let stillMounted = self.lastBusy.isEmpty
                ? "Some volumes are still mounted." : "Still mounted: \(self.lastBusy.joined(separator: ", "))."
            var content = OverlayContent(
                tone: planned ? .info : .alarm, title: "Can't unmount: the SSD is in use",
                message: (note.map { $0 + " " } ?? "") + stillMounted
                    + " Stop the programs below, then press Try again. Or force the unmount.")
            if r.timedOut {
                content.details = self.lastBusyWhy + ["(lsof took longer than 45 seconds and was stopped; the list may be incomplete)"] + users
            } else if !r.ok {
                let why = r.lines("FAILED").first?.joined(separator: " ") ?? "exit status \(r.status)"
                content.details = self.lastBusyWhy + ["(could not list what uses the SSD: \(why))"]
            } else if !r.lines("WARN").isEmpty {
                content.details = self.lastBusyWhy + ["(lsof reported errors; the list may be incomplete)"] + users
            } else {
                content.details = self.lastBusyWhy
                    + (users.isEmpty ? ["(none of your programs has files open there. macOS services are not visible"
                                        + " to lsof without admin rights: diskutil's reason above names who refused)"] : users)
            }
            content.buttons = [
                OverlayButton("Try again", .primary) { [weak self] in self?.unmountRest(planned: planned) },
                OverlayButton("Force unmount…", .destructive) { [weak self] in self?.confirmForce(planned: planned, users: users) },
                OverlayButton("Dismiss") { [weak self] in self?.cancelUnmount(planned: planned) },
            ]
            self.ask(content)
        }
    }

    private static func userLines(_ r: JobResult) -> [String] {
        r.lines("USER").map { f in
            guard f.count >= 4 else { return f.joined(separator: " ") }
            let what = f[2] == "cwd" ? "working folder" : f[2] == "system" ? "macOS service, usually lets go by itself:" : "open file"
            return "\(f[0]) (pid \(f[1])): \(what) \(Paths.tilde(f[3]))"
        }
    }

    private func confirmForce(planned: Bool, users: [String]) {
        var content = OverlayContent(
            tone: .alarm, title: "Force unmount?",
            message: "These programs lose the files they have open on the SSD, and unsaved work in them can be lost. "
                + "Shells and agents only show errors until the SSD is back.")
        content.details = users
        content.buttons = [
            OverlayButton("Force unmount", .destructive) { [weak self] in self?.forceUnmount(planned: planned) },
            OverlayButton("Back") { [weak self] in self?.showUsers(planned: planned) },
        ]
        ask(content)
    }

    private func forceUnmount(planned: Bool) {
        working(OverlayContent(tone: .progress, title: "Forcing the unmount", progress: -1,
                               progressLabel: "diskutil unmount force"))
        Log.write("force unmount")
        run(Paths.off, ["--step", "force"], timeout: 90) { [weak self] r in
            guard let self else { return }
            self.unmountedByApp.formUnion(r.lines("UNMOUNTED").compactMap(\.first))
            if r.ok {
                self.eject(planned: planned)
            } else {
                self.unmountProblem(planned: planned, title: "Force unmount failed",
                                    message: r.timedOut ? "diskutil did not finish within 90 seconds and was stopped." : "Some volumes are still mounted.",
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
                var content = OverlayContent(
                    tone: .info, title: "Safe to unplug",
                    message: "Unplug the SSD, wait 5 seconds, then plug it back in. The resume starts by itself as soon as it is back.")
                content.buttons = [OverlayButton("OK", .primary) { [weak self] in self?.closeResult() }]
                content.onClick = { [weak self] in self?.closeResult() }
                self.ask(content)
            } else {
                self.unmountProblem(planned: planned, title: "Eject failed",
                                    message: r.timedOut ? "diskutil did not finish within 60 seconds and was stopped." : (r.lines("FAILED").first?.first ?? r.tail(1).first ?? ""),
                                    details: [], retry: { [weak self] in self?.eject(planned: planned) })
            }
        }
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
            if visible { self.overlay.hide() } else { self.overlay.unhide() }
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
