import Foundation

/// The resume after the SSD comes back: six steps, each with its own time limit.
/// Everything that touches the SSD runs as `ssd-resume --step …` with a time limit; the app itself only
/// reads the kernel's cached mount table, so it can't hang on a dying disk.
/// Every step is safe to repeat, so a stopped resume can continue from the step that stopped.
@MainActor
final class ResumeRunner {
    enum Step: Int, CaseIterable {
        case volumes, services, locks, verify, report, record

        var title: String {
            switch self {
            case .volumes: return "Waiting for the volumes"
            case .services: return "Restarting services"
            case .locks: return "Removing stale git locks"
            case .verify: return "Checking everything"
            case .report: return "Listing what to restart"
            case .record: return "Saving the connection"
            }
        }

        /// Share of the progress bar.
        var weight: Double {
            switch self {
            case .volumes: return 0.30
            case .services: return 0.25
            case .locks: return 0.20
            case .verify: return 0.10
            case .report: return 0.10
            case .record: return 0.05
            }
        }

        /// Time limit for the step's command. While a password dialog is up the clock stops.
        /// A step that fails or runs over stops the resume, with Resume again / Start over.
        var timeout: TimeInterval {
            switch self {
            case .volumes: return 60      // the mount command, after the 30 s wait for macOS
            case .services: return 120    // each service gets up to 30 s to stop after SIGTERM
            case .locks: return 120       // walks every repo under ~/Repo (about 10 s warm; slower right after a replug)
            case .verify: return 10
            case .report: return 30
            case .record: return 15
            }
        }
    }

    struct Summary {
        var mountedByApp: [String] = []
        var restarted: [String] = []
        var locksRemoved: [String] = []   // paths
        var notes: [String] = []
        var apps: [String] = []
        var jobs: [String] = []
    }

    /// Append what is not there yet, in order.
    static func add(_ items: [String], to list: inout [String]) {
        for item in items where !list.contains(item) { list.append(item) }
    }

    enum Outcome {
        case success(Summary)
        case failure(step: Step, reason: String, output: [String])
    }

    /// Volumes macOS gets to mount by itself before the app mounts the missing ones.
    static let mountWait: TimeInterval = 30

    private let health: () -> Health
    private let serviceVolumes: [String]?
    private let passwordWatch = PasswordWatch()
    private var job: Job?
    private var mountWaitTimer: Timer?
    private var mountWaitLeft: TimeInterval = 0
    private var mountWaitSince: TimeInterval = 0
    private var mountWaitPaused = false
    private var verifyWaitTimer: Timer?
    private var latest: Health?
    private var mountTried = false
    private var finished = false
    private(set) var step: Step = .volumes
    private(set) var detail = ""
    private(set) var summary = Summary()

    var onProgress: (() -> Void)?
    var onPasswordDialog: ((Bool) -> Void)?
    var onDone: ((Outcome) -> Void)?

    /// `serviceVolumes`: restart only the services tied to these volumes; nil restarts them only if the
    /// SSD was reconnected since the last resume (a manual run).
    init(serviceVolumes: [String]?, health: @escaping () -> Health) {
        self.serviceVolumes = serviceVolumes
        self.health = health
        // A password dialog stops every clock of the resume: the wait for the volumes and the step's limit.
        passwordWatch.onChange = { [weak self] visible in
            guard let self else { return }
            if visible { self.job?.pauseTimeout(); self.pauseMountWait() } else { self.job?.resumeTimeout(); self.resumeMountWait() }
            self.onPasswordDialog?(visible)
        }
    }

    /// A fresh snapshot of the mount table, kept for the progress bar until the next one.
    private func read() -> Health {
        let h = health()
        latest = h
        return h
    }

    var fraction: Double {
        if finished { return 1 }
        let done = Step.allCases.filter { $0.rawValue < step.rawValue }.reduce(0) { $0 + $1.weight }
        guard step == .volumes else { return done + step.weight * 0.3 }   // the mount table only matters here
        let h = latest ?? read()
        return done + step.weight * (h.volumes.isEmpty ? 0.3 : Double(h.okCount) / Double(h.volumes.count))
    }

    var label: String {
        "Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)\(detail.isEmpty ? "" : " (\(detail))")"
    }

    /// One line per step: done, running, or still to come.
    var checklist: [String] {
        Step.allCases.map { s in
            let mark = s.rawValue < step.rawValue || finished ? "✓" : (s == step ? "›" : " ")
            return "\(mark) \(s.title)"
        }
    }

    func start(from first: Step) {
        cancelWork()
        finished = false
        // Start over keeps the summary: what earlier runs did (services stopped, locks removed) still happened.
        if first == .volumes { mountTried = false }
        passwordWatch.start()   // for the whole resume (once a second, only while it runs)
        run(first)
    }

    func cancel() {
        finished = true
        cancelWork()
    }

    /// For quitting: stop the running step's command at once.
    func killNow() {
        job?.killNow()
        cancel()
    }

    /// The disk watcher saw a change; matters only while waiting for the volumes.
    /// The disk watcher saw a change. `h` is the snapshot the app just read (not read again here).
    func healthChanged(_ h: Health) {
        latest = h
        guard !finished else { return }
        if step == .verify, verifyWaitTimer != nil, job == nil, h.allOK { verify(); return }
        guard step == .volumes else { return }
        detail = "\(h.okCount) of \(h.volumes.count) mounted"
        if h.allOK, job == nil {
            next()
        } else {
            onProgress?()
        }
    }

    // MARK: - steps

    private func run(_ s: Step) {
        step = s
        detail = ""
        Log.write("resume step: \(s.title)")
        switch s {
        case .volumes:
            let h = read()
            if h.allOK { next(); return }
            detail = "\(h.okCount) of \(h.volumes.count) mounted"
            if mountTried {
                mountMissing()
            } else {
                armMountWait(ResumeRunner.mountWait)
                if passwordWatch.visible { pauseMountWait() }
            }
        case .services:
            var args = ["--step", "services"]
            if let serviceVolumes { args += ["--volumes", serviceVolumes.joined(separator: ",")] }
            // What a step did is kept even when it then fails: a retry won't redo it, and the summary must
            // still show it. Kept without repeats.
            runScript(args) { [weak self] r in
                guard let self else { return }
                ResumeRunner.add(r.lines("RESTARTED").compactMap(\.first), to: &self.summary.restarted)
                ResumeRunner.add(r.lines("SKIPPED").compactMap(\.first).filter { !$0.hasPrefix("no reconnect") },
                                 to: &self.summary.notes)
            }
        case .locks:
            runScript(["--step", "locks"]) { [weak self] r in
                guard let self else { return }
                ResumeRunner.add(r.lines("REMOVED").compactMap(\.first), to: &self.summary.locksRemoved)
                ResumeRunner.add(r.lines("SKIPPED").compactMap(\.first), to: &self.summary.notes)
            }
        case .verify:
            verify()
        case .report:
            runScript(["--step", "report"]) { [weak self] r in
                guard r.ok, let self else { return }   // a list only from a finished run
                self.summary.apps = r.lines("APP").compactMap(\.first)
                self.summary.jobs = r.lines("JOB").compactMap { f in
                    f.count >= 3 ? "\(f[0]) (pid \(f[1])) in \(Paths.tilde(f[2]))" : nil
                }
                ResumeRunner.add(r.lines("WARN").compactMap(\.first), to: &self.summary.notes)
            }
        case .record:
            runScript(["--step", "record"]) { _ in }
        }
        onProgress?()
    }

    private func next() {
        guard !finished else { return }
        stopMountWait()
        stopVerifyWait()
        if let following = Step(rawValue: step.rawValue + 1) {
            run(following)
        } else {
            finished = true
            passwordWatch.stop()
            Log.write("resume finished")
            onDone?(.success(summary))
        }
    }

    private func fail(_ reason: String, output: [String] = []) {
        guard !finished else { return }
        finished = true
        cancelWork()
        Log.write("resume stopped at \(step.title): \(reason)")
        onDone?(.failure(step: step, reason: reason, output: output))
    }

    /// macOS did not mount everything within the wait: mount the rest (plain `diskutil mount`, no password).
    private func mountMissing() {
        stopMountWait()
        guard !finished, step == .volumes else { return }
        if read().allOK { next(); return }
        mountTried = true
        detail = "mounting the missing volumes"
        onProgress?()
        startJob(["--step", "mounts"]) { [weak self] r in
            guard let self, !self.finished else { return }
            let h = self.read()
            ResumeRunner.add(r.lines("MOUNTED").compactMap(\.first), to: &self.summary.mountedByApp)
            if h.allOK {
                self.next()
            } else if r.timedOut {
                self.fail("Mounting took longer than \(Int(Step.volumes.timeout)) seconds and was stopped.", output: r.tail(12))
            } else {
                let missing = h.bad.map { "\($0.volume.name) (\($0.state.short))" }.joined(separator: ", ")
                self.fail("These volumes did not mount: \(missing).",
                          output: r.lines("FAILED").map { "\($0.first ?? ""): \($0.dropFirst().joined(separator: " "))" })
            }
        }
    }

    /// All volumes in place (mount table), then a test file in ~/Repo (a script step, so a hung disk only
    /// costs the step's time limit).
    private func verify() {
        let h = read()
        guard h.allOK else {
            // Missing right now may be a blip: the app's 3-second rule decides (back: this goes on; gone: the
            // resume starts over). If neither has happened within 10 s, the step fails.
            if verifyWaitTimer == nil {
                detail = "waiting for " + h.bad.map(\.volume.name).joined(separator: ", ")
                let t = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.verifyGaveUp() }
                }
                t.tolerance = 1
                RunLoop.main.add(t, forMode: .common)
                verifyWaitTimer = t
                onProgress?()
            }
            return
        }
        stopVerifyWait()
        runScript(["--step", "writable"]) { _ in }
    }

    private func verifyGaveUp() {
        verifyWaitTimer = nil
        guard !finished, step == .verify, job == nil else { return }
        let h = read()
        if h.allOK { verify(); return }
        fail("Not all volumes are in place: " + h.bad.map { "\($0.volume.name) \($0.state.short)" }.joined(separator: ", "))
    }

    private func stopVerifyWait() {
        verifyWaitTimer?.invalidate()
        verifyWaitTimer = nil
    }

    /// Run `ssd-resume` with these arguments for the current step; then parse and go on, or fail.
    private func runScript(_ args: [String], parse: @escaping (JobResult) -> Void) {
        let current = step
        startJob(args) { [weak self] r in
            guard let self, !self.finished, self.step == current else { return }
            parse(r)   // also when it failed: what it did before failing counts
            if r.ok {
                self.next()
            } else if r.timedOut {
                self.fail("\(current.title) took longer than \(Int(current.timeout)) seconds and was stopped.",
                          output: r.tail(12))
            } else if let failed = r.lines("FAILED").first {
                self.fail("\(current.title) failed: \(failed.joined(separator: ": ")).", output: r.tail(12))
            } else {
                self.fail("\(current.title) failed (exit status \(r.status)).", output: r.tail(12))
            }
        }
    }

    private func startJob(_ args: [String], completion: @escaping (JobResult) -> Void) {
        var created: Job?
        let job = Job(Paths.resume, args, label: "ssd-resume " + args.joined(separator: " "),
                      timeout: step.timeout) { [weak self] r in
            // A job that was cancelled or replaced in the meantime reports to nobody.
            guard let self, let created, self.job === created else { return }
            self.job = nil
            completion(r)
        }
        created = job
        self.job = job
        job.start()
        if passwordWatch.visible { job.pauseTimeout() }   // a dialog is already up: the clock starts stopped
    }

    // MARK: - the wait for the volumes, pausable like a step's time limit

    private func armMountWait(_ seconds: TimeInterval) {
        mountWaitTimer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.mountMissing() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        mountWaitTimer = t
        mountWaitLeft = seconds
        mountWaitSince = ProcessInfo.processInfo.systemUptime
        mountWaitPaused = false
    }

    private func pauseMountWait() {
        guard let t = mountWaitTimer else { return }
        t.invalidate()
        mountWaitTimer = nil
        mountWaitLeft = max(1, mountWaitLeft - (ProcessInfo.processInfo.systemUptime - mountWaitSince))
        mountWaitPaused = true
    }

    private func resumeMountWait() {
        guard mountWaitPaused, !finished, step == .volumes else { return }
        armMountWait(mountWaitLeft)
    }

    private func stopMountWait() {
        mountWaitTimer?.invalidate()
        mountWaitTimer = nil
        mountWaitPaused = false
    }

    private func cancelWork() {
        let running = job
        job = nil
        running?.cancel()
        stopMountWait()
        stopVerifyWait()
        passwordWatch.stop()
    }
}
