import AppKit
import Darwin

/// Result of one finished command. Output is stdout and stderr together.
struct JobResult {
    let status: Int32
    let output: String
    let timedOut: Bool
    let cancelled: Bool

    var ok: Bool { status == 0 && !timedOut && !cancelled }

    /// Fields of the tab-separated lines that start with `kind` (the scripts' step output), without the kind.
    func lines(_ kind: String) -> [[String]] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.first == kind ? Array(fields.dropFirst()) : nil
        }
    }

    func tail(_ count: Int) -> [String] {
        output.split(separator: "\n").suffix(count).map(String.init)
    }
}

/// One external command (the ssd-resume / ssd-off steps) with a timeout.
/// Output goes to a temp file and is read once the command exits: nothing to drain, nothing that can hang
/// if something it started keeps running. The timeout can be paused while macOS shows a password dialog.
/// On timeout or cancel the command and everything it started are stopped; if it can't be stopped (stuck
/// on a dead disk), the job reports anyway, so no screen waits for it. All on the main thread.
final class Job {
    /// After SIGTERM: SIGKILL, then give up on the command this much later.
    static let killDelay: TimeInterval = 2
    static let abandonDelay: TimeInterval = 3
    /// Only the end of a longer output is read.
    static let outputLimit: UInt64 = 1_000_000

    private let process = Process()
    /// The job's own scratch folder: the output file, and the scripts' temp files (their TMPDIR). Removed when
    /// the job ends, even if the command had to be given up on.
    private let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ssd-monitor-\(UUID().uuidString)")
    private var outputURL: URL { scratch.appendingPathComponent("output") }
    private var timer: DispatchSourceTimer?
    private var remaining: TimeInterval
    private var armedAt: TimeInterval = 0          // system uptime: a clock that can't be set back
    private var exited = false
    private var stopping = false
    private var timedOut = false
    private var cancelled = false
    private var completion: (@MainActor (JobResult) -> Void)?

    let label: String

    init(_ executable: String, _ arguments: [String], label: String, timeout: TimeInterval,
         completion: @escaping @MainActor (JobResult) -> Void) {
        self.label = label
        self.remaining = timeout
        self.completion = completion
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }

    func start() {
        process.currentDirectoryURL = URL(fileURLWithPath: "/")   // never hold an SSD folder open
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["TMPDIR"] = scratch.path + "/"
        process.environment = env
        process.standardInput = FileHandle.nullDevice              // not a terminal: no password fallbacks
        // Holds the job until the command exits (cleared in didExit), so its output file is always removed.
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { self.didExit(status) }
        }
        Log.write("run \(label)")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            process.standardOutput = output
            process.standardError = output
            defer { try? output.close() }                          // the child keeps its own copy
            try process.run()
        } catch {
            process.terminationHandler = nil
            exited = true
            finish(status: -1, extra: "could not start \(process.executableURL?.path ?? ""): \(error.localizedDescription)")
            return
        }
        arm(remaining)
    }

    /// Stop counting toward the timeout (a password dialog is up). Safe to call repeatedly. After the dialog
    /// the command gets at least 5 s more, so it isn't stopped the moment the password went in.
    func pauseTimeout() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        remaining = max(5, remaining - (ProcessInfo.processInfo.systemUptime - armedAt))
    }

    func resumeTimeout() {
        guard timer == nil, !exited, !stopping, completion != nil else { return }
        arm(remaining)
    }

    func cancel() {
        guard !exited, completion != nil else { return }
        cancelled = true
        stop()
    }

    /// For quitting: stop the command and everything it started right away, SIGTERM then SIGKILL, without
    /// waiting for the main queue (the app is about to go).
    func killNow() {
        let group = process.processIdentifier
        guard !exited, group > 0 else { return }
        killpg(group, SIGTERM)
        usleep(300_000)
        killpg(group, SIGKILL)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - private

    private func arm(_ seconds: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, !self.exited else { return }
            self.timedOut = true
            Log.write("timeout \(self.label) after \(Int(seconds))s")
            self.stop()
        }
        armedAt = ProcessInfo.processInfo.systemUptime
        timer = t
        t.resume()
    }

    /// Process starts every command as the leader of its own process group, and the scripts' children stay
    /// in it: signalling the group reaches all of them, even after the shell itself has exited.
    private func stop() {
        guard !stopping else { return }
        stopping = true
        timer?.cancel()
        timer = nil
        let group = process.processIdentifier
        guard group > 0 else { return }
        killpg(group, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + Job.killDelay) { [weak self] in
            killpg(group, SIGKILL)      // leftovers too; an empty group just answers ESRCH
            self?.abandonLater()
        }
    }

    /// A command stuck in the kernel on a dead disk may not die even from SIGKILL: report it as stopped
    /// a moment later anyway. Its late exit is then ignored.
    private func abandonLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Job.abandonDelay) { [weak self] in
            guard let self, !self.exited, self.completion != nil else { return }
            Log.write("\(self.label) did not exit after SIGKILL; reported as stopped")
            self.process.terminationHandler = nil   // let the job go; nothing waits for that exit any more
            self.finish(status: -1, extra: "The command did not stop (stuck on the disk?).")
        }
    }

    private func didExit(_ status: Int32) {
        exited = true
        process.terminationHandler = nil
        timer?.cancel()
        timer = nil
        finish(status: status, extra: nil)
    }

    private func finish(status: Int32, extra: String?) {
        guard let completion else { return }
        self.completion = nil
        var data = Data()
        if let handle = try? FileHandle(forReadingFrom: outputURL) {   // a temp file on the Mac's own disk
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > Job.outputLimit ? size - Job.outputLimit : 0)
            data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: scratch)
        var text = String(decoding: data, as: UTF8.self)
        if let extra { text += (text.isEmpty ? "" : "\n") + extra }
        let result = JobResult(status: status, output: text, timedOut: timedOut, cancelled: cancelled)
        Log.write("done \(label): status \(status)\(timedOut ? " (timed out)" : "")\(cancelled ? " (cancelled)" : "")")
        MainActor.assumeIsolated { completion(result) }
    }
}

/// Is macOS showing a password dialog (SecurityAgent) right now? Checked once a second, and only while
/// a command or the resume runs.
enum PasswordDialog {
    static func isVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        else { return false }
        // Only the owner name of each window is read (no conversion of every window's whole dictionary).
        let windows = list as NSArray
        for case let info as NSDictionary in windows {
            if let owner = info[kCGWindowOwnerName as String] as? String,
               owner == "SecurityAgent" || owner == "coreautha" { return true }
        }
        return false
    }
}

/// Polls for a password dialog once a second while active; reports changes only.
@MainActor
final class PasswordWatch {
    private var timer: Timer?
    private(set) var visible = false
    var onChange: ((Bool) -> Void)?

    deinit {
        timer?.invalidate()   // never leave a once-a-second timer behind
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if visible { visible = false; onChange?(false) }
    }

    private func check() {
        let now = PasswordDialog.isVisible()
        guard now != visible else { return }
        visible = now
        Log.write(now ? "password dialog visible" : "password dialog gone")
        onChange?(now)
    }
}
