import Foundation
import Darwin

/// The programs reading and writing the SSD: Apple's fs_usage, disk I/O events only, started through the sudo
/// rule (`sudo -k -n`: never a password prompt, never a cached login) while the Statistics window is open.
///
/// - fs_usage writes to a pseudo-terminal, so it sends each line as it happens (to a pipe it would send them in
///   16 KB blocks, seconds late on a quiet Mac).
/// - Each run ends by itself after `SudoRule.traceSeconds` (`-t`), and a new one starts while the trace is
///   wanted. So nothing outlives the app by more than that, whatever happens to the app. Stopping closes the
///   reader and sends SIGTERM to sudo, which passes it on (if sudo ran fs_usage in its own place, the app may not
///   signal a root process: then the time limit ends it).
/// - The kernel allows one trace at a time: a trace starts only once every earlier one has exited, and a trace
///   that wants another run lets a waiting one go first.
/// - Lines are parsed on a background queue. Only the SSD's reach the main thread, summed per volume and program
///   for the second they arrived in. File paths are used only to tell which volume an I/O belongs to.
///
/// Its state is split by thread on purpose (main actor / the queue / the lock), hence `@unchecked Sendable`.
final class ProgramTrace: @unchecked Sendable {
    enum State: Equatable {
        case starting
        case running
        case needsSetup          // sudo wanted a password: the rule is missing or doesn't match
        case failed(String)
    }
    /// `volume` nil: the SSD's own traffic no volume owns ("APFS shared").
    struct Key: Hashable { let volume: String?; let program: String }
    struct Batch {
        let generation: Int
        let second: Int          // `clock`, whole seconds, when the lines came in
        let at: TimeInterval     // `clock`, exactly
        var bytes: [Key: (read: UInt64, written: UInt64)]
    }
    /// Where the SSD is now: its volumes' devices and mount paths, the whole disk and the APFS container.
    struct Devices {
        var volumes: [String: String] = [:]       // BSD name -> volume name
        var mounts: [(path: String, name: String)] = []
        var whole: String?
        var container: String?

        func isSSD(_ device: String) -> Bool {
            if volumes[device] != nil { return true }
            for base in [whole, container].compactMap({ $0 }) where device == base || device.hasPrefix(base + "s") {
                return true
            }
            return false
        }

        /// The volume an I/O belongs to: by its device, else by its file's whole path; nil if neither tells
        /// (a path fs_usage may have cut to its end could match the wrong mount point).
        func volume(device: String, path: String, pathMayBeCut: Bool) -> String? {
            if let name = volumes[device] { return name }
            guard !pathMayBeCut, path.hasPrefix("/") else { return nil }
            var best: (length: Int, name: String)?
            for mount in mounts where path == mount.path || path.hasPrefix(mount.path + "/") {
                if mount.path.count > best?.length ?? -1 { best = (mount.path.count, mount.name) }
            }
            return best?.name
        }
    }

    /// Called on the main thread, never after `stop()`. `onLaunch`: each time an fs_usage run starts.
    /// `current`: parsed under the current device map (only those count for the live rates).
    var onBatch: (@MainActor (Batch, _ current: Bool) -> Void)?
    var onState: (@MainActor (State) -> Void)?
    var onLaunch: (@MainActor () -> Void)?
    /// fs_usage reported dropped events (also after `stop()`, for the runs still finishing).
    var onDropped: (@MainActor () -> Void)?
    /// Its first record (any disk) came in, at this `clock` time: tracing surely ran from then (also after
    /// `stop()`).
    var onCoverage: (@MainActor (TimeInterval) -> Void)?
    @MainActor private(set) var state = State.starting
    /// sudo's own words when it refused to run fs_usage (state .needsSetup), for the setup and Settings to show.
    @MainActor private(set) var refusal: String?
    /// `clock` when its first fs_usage started: nothing can have been counted before.
    @MainActor private(set) var launchedAt: TimeInterval?
    /// When fs_usage last said it dropped events ("buffer overrun": the Mac was too busy to trace everything).
    @MainActor private(set) var droppedAt: TimeInterval?
    @MainActor private var errors: ScratchOutput?
    @MainActor private var errorsRead = 0               // how much of this run's error output was looked at

    /// Seconds on a clock that keeps running while the Mac sleeps (CLOCK_MONOTONIC), so a gap stays a gap.
    static var clock: TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }

    @MainActor private static var running = 0              // processes started and not yet exited
    @MainActor private static var stopping: [ChildProcess] = []   // stops whose signal was refused so far
    @MainActor private static var waiting: [ProgramTrace] = []

    @MainActor private var child: ChildProcess?          // the current run's sudo
    /// The recent runs, by `clock`: launched, first record seen (tracing surely on), ended.
    @MainActor private var runs: [(start: TimeInterval, traced: TimeInterval?, end: TimeInterval?)] = []
    private let queue = DispatchQueue(label: "ssd-monitor.program-trace")
    private let lock = NSLock()
    private var devices = Devices()                        // under lock
    private var generation = 0                             // under lock
    @MainActor private var stopped = false
    @MainActor private var everRan = false
    // The queue's own:
    private var source: DispatchSourceRead?
    private var readerClosed = false
    private var sawRecord = false
    private var runSawRecord = false
    private var pending: [UInt8] = []
    private var buffer = [UInt8](repeating: 0, count: 65536)

    /// Changes when the SSD comes back (new devices); batches from before carry the old generation.
    @discardableResult
    func setDevices(_ new: Devices) -> Int {
        lock.lock()
        defer { lock.unlock() }
        devices = new
        generation += 1
        return generation
    }

    @MainActor
    func start() {
        guard !stopped else { return }
        if ProgramTrace.running > 0 {
            if !ProgramTrace.waiting.contains(where: { $0 === self }) { ProgramTrace.waiting.append(self) }
            return
        }
        launch()
    }

    @MainActor
    func stop() {
        guard !stopped else { return }
        stopped = true
        onState = nil   // onBatch stays: batches already parsed still reach the history (not the live rates)
        onLaunch = nil
        ProgramTrace.waiting.removeAll { $0 === self }
        queue.async { self.closeReader() }                 // its output is no longer wanted
        if let child { signalUntilDelivered(child, tries: 200) }
    }

    /// SIGTERM to sudo, which passes it on to fs_usage (never to a process that got sudo's ID later). While sudo
    /// starts it briefly runs as root, and the signal is refused (EPERM): then again every 0.2 s until it lands,
    /// sudo has gone, or sudo's own limit has passed.
    @MainActor
    private func signalUntilDelivered(_ child: ChildProcess, tries: Int) {
        switch child.signal(SIGTERM) {
        case 0:
            ProgramTrace.stopping.removeAll { $0 === child }
            Log.write("program list: fs_usage stopped")
        case EPERM where tries > 1:
            if !ProgramTrace.stopping.contains(where: { $0 === child }) { ProgramTrace.stopping.append(child) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self.signalUntilDelivered(child, tries: tries - 1) }
            }
        case let error:
            ProgramTrace.stopping.removeAll { $0 === child }
            if error != ESRCH { Log.write("program list: can't signal fs_usage (errno \(error)); sudo ends it within \(SudoRule.sudoTimeout) s") }
        }
    }

    /// For quitting: are stops still waiting for sudo to accept the signal? `finishStopping` tries them once
    /// more and says whether any is left.
    @MainActor
    static func finishStopping() -> Bool {
        stopping.removeAll { $0.signal(SIGTERM) != EPERM }
        return !stopping.isEmpty
    }

    // MARK: - private

    @MainActor
    private func launch() {
        var master: Int32 = -1
        var slave: Int32 = -1
        var term = termios()
        cfmakeraw(&term)                                   // no "\r\n", no echo
        var size = winsize(ws_row: 50, ws_col: 264, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, &term, &size) == 0 else {
            return report(.failed("could not open a pseudo-terminal (errno \(errno))"))
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)   // draining it can never block
        guard let errors = ScratchOutput() else {
            close(master)
            close(slave)
            return report(.failed("could not create a temp file"))
        }
        // The reader is set up first, so the exit's drain (queued later on the same queue) always finds it.
        queue.async { self.read(from: master) }
        // In a session of its own (ChildProcess): sudo never moves fs_usage onto a terminal of its own, even
        // when the app was started from one.
        let spawned = ChildProcess.spawn("/usr/bin/sudo", SudoRule.sudoArguments, stdout: slave,
                                         stderr: errors.handle.fileDescriptor) { code in
            // On the waiting thread, after the reap: when the run ended (not when the main thread hears of it),
            // then the reader takes in the run's last output first.
            let endedAt = ProgramTrace.clock
            self.queue.async {
                self.drain()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.exited(code, errors: errors, endedAt: endedAt) }
                }
            }
        }
        close(slave)                                       // the child has its own: the reader ends when it does
        switch spawned {
        case .failure(let error):
            queue.async { self.closeReader() }
            return report(.failed("could not start sudo: \(error.localizedDescription)"))
        case .success(let child):
            self.child = child
        }
        self.errors = errors
        errorsRead = 0
        ProgramTrace.running += 1
        let now = ProgramTrace.clock
        if launchedAt == nil { launchedAt = now }
        runs.append((now, nil, nil))
        if runs.count > 8 { runs.removeFirst(runs.count - 8) }
        if !everRan { Log.write("program list: fs_usage started") }
        onLaunch?()
    }

    /// How much of [from, to) fs_usage was running for (its runs restart every 30 s, with a short gap).
    /// When the first run began tracing (its first record, else its launch), by `clock`.
    @MainActor var firstCoverage: TimeInterval? { runs.first.map { $0.traced ?? $0.start } }

    @MainActor
    func watched(from: TimeInterval, to: TimeInterval) -> TimeInterval {
        var total: TimeInterval = 0
        for run in runs {
            // From the run's first record (sudo's own start-up isn't tracing time); a run with none counts from
            // its launch (it saw nothing, so it adds no traffic either way).
            let start = max(run.traced ?? run.start, from)
            let end = min(run.end ?? to, to)
            if end > start { total += end - start }
        }
        return total
    }

    @MainActor
    private func exited(_ status: Int32, errors: ScratchOutput, endedAt: TimeInterval) {
        let text = errors.text()
        if self.errors === errors { checkDropped() }
        ProgramTrace.running -= 1
        child = nil
        if let last = runs.indices.last, runs[last].end == nil { runs[last].end = endedAt }
        defer { ProgramTrace.startNextWaiting() }
        guard !stopped else { return }
        if status == 0, !SudoRule.isInstalled {
            report(.needsSetup)   // the rule went (removed elsewhere): no next run
        } else if status == 0, state == .running || state == .starting {
            // A run that went its full time and ended cleanly proves sudo ran fs_usage, even on a Mac so quiet
            // that it saw no disk I/O.
            if state == .starting {
                everRan = true
                report(.running)
                guard !stopped else { return }   // whoever was waiting for that may have stopped it
            }
            // The run's time limit (a quiet run that saw no record yet included): the next one, while the trace
            // is wanted; a waiting trace goes first.
            if ProgramTrace.waiting.isEmpty { launch() } else { ProgramTrace.waiting.append(self) }
        } else if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("sudo:") }) {
            // sudo didn't run it (no rule, a rule it ignores, a policy that refuses `-T` or wants a terminal).
            refusal = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            report(.needsSetup)
        } else if text.contains("Resource busy") {
            // Another trace holds the kernel's one trace (perhaps one a crashed run left: sudo ends it in 40 s).
            report(.failed("another program is tracing the system right now (one left over ends within \(SudoRule.sudoTimeout) s). Try again shortly."))
        } else {
            let last = text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            report(.failed(last.isEmpty ? "fs_usage stopped (exit status \(status))" : last))
        }
    }

    /// Has fs_usage reported dropped events since the last look? Reads its error output (a small file).
    @MainActor
    func checkDropped() {
        guard let errors else { return }
        let size = errors.size
        guard size > errorsRead else { return }
        // Back up a little, in case the last look ended in the middle of the message.
        let new = errors.text(from: max(0, errorsRead - 32), limit: 65536)
        errorsRead = size
        if new.contains("buffer overrun") {
            if droppedAt == nil { Log.write("program list: fs_usage dropped events (busy Mac)") }
            droppedAt = ProgramTrace.clock
            onDropped?()
        }
    }

    @MainActor
    private static func startNextWaiting() {
        guard running == 0, !waiting.isEmpty else { return }
        waiting.removeFirst().launch()
    }

    @MainActor
    private func report(_ new: State) {
        guard !stopped, new != state else { return }
        state = new
        switch new {
        case .starting, .running: break
        case .needsSetup: Log.write("program list: sudo wants a password (no rule)")
        case .failed(let why): Log.write("program list: \(why)")
        }
        onState?(new)
    }

    @MainActor
    private func deliver(_ batch: Batch) {
        lock.lock()
        let current = generation
        lock.unlock()
        onBatch?(batch, !stopped && batch.generation == current)
    }

    /// On the queue: read the pseudo-terminal until fs_usage has gone (EOF, or EIO once nothing holds the
    /// other end), parse the complete lines, send the SSD's on.
    private func read(from fd: Int32) {
        if readerClosed {                                  // stopped before it began
            close(fd)
            return
        }
        self.source?.cancel()                              // the previous run's, whose process has exited
        pending.removeAll()
        runSawRecord = false
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The handler holds the source until it is cancelled (dispatch then lets go of the handler).
        source.setEventHandler {
            let n = self.buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            guard n > 0 else {
                // The end: let go of it before it closes the descriptor, so nothing reads that number again.
                if self.source === source { self.source = nil }
                return source.cancel()
            }
            self.parse(count: n)
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// On the queue, once the run's process has exited: take in what is still unread, then end the reader.
    private func drain() {
        guard let source, !readerClosed else { return }
        let fd = Int32(source.handle)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            parse(count: n)
        }
        source.cancel()
        self.source = nil
    }

    /// On the queue: no more reading (stopped). fs_usage's further writes fail until it ends.
    private func closeReader() {
        readerClosed = true
        source?.cancel()
        source = nil
        pending.removeAll()
    }

    private func parse(count: Int) {
        pending.append(contentsOf: buffer[0..<count])
        lock.lock()
        let devices = self.devices
        let generation = self.generation
        lock.unlock()
        let now = ProgramTrace.clock
        var batch = Batch(generation: generation, second: Int(now), at: now, bytes: [:])
        var lineStart = 0
        for i in 0..<pending.count where pending[i] == 10 {
            // The first complete disk I/O record (any disk) proves sudo ran fs_usage and the kernel trace runs;
            // other output (a message from sudo, say) doesn't.
            if !runSawRecord, FsUsageLine.parse(pending[lineStart..<i], wanted: { _ in true }) != nil {
                runSawRecord = true
                let first = !sawRecord
                sawRecord = true
                let at = ProgramTrace.clock
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let last = self.runs.indices.last, self.runs[last].traced == nil { self.runs[last].traced = at }
                        if first { self.onCoverage?(at) }
                        guard first, !self.stopped, self.state == .starting else { return }
                        self.everRan = true
                        self.report(.running)
                    }
                }
            }
            if let line = FsUsageLine.parse(pending[lineStart..<i], wanted: devices.isSSD) {
                let key = Key(volume: devices.volume(device: line.device, path: line.path, pathMayBeCut: line.pathMayBeCut),
                              program: line.program)
                var bytes = batch.bytes[key] ?? (0, 0)
                if line.isRead { bytes.read = bytes.read.addingSaturated(line.bytes) }
                else { bytes.written = bytes.written.addingSaturated(line.bytes) }
                batch.bytes[key] = bytes
            }
            lineStart = i + 1
        }
        pending.removeFirst(lineStart)
        if pending.count > 65536 { pending.removeAll() }   // no line end in 64 KB: not fs_usage's output
        if !batch.bytes.isEmpty {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(batch) } }
        }
    }
}

extension UInt64 {
    func addingSaturated(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
