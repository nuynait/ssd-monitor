import Foundation

/// The one sudo rule the Statistics window's program list needs: this user (by user ID) may run exactly
/// `/usr/bin/fs_usage -w -f diskio -t 30` as root without a password. Other arguments, and other commands,
/// still ask. `-t 30` makes every run end by itself after 30 s (the app starts the next one while the window is
/// open). sudo's own time limit (`sudo -T 40`, allowed for fs_usage by the file's Defaults line, and the rule's
/// `TIMEOUT=40` too) makes sudo stay as its supervisor (it never runs a command with a time limit in its own
/// place, so the app can always signal it) and end it after 40 s even if fs_usage hangs. So a trace can never
/// outlive the app by more than that. (Not `-F`, which would keep the front of a long path: macOS 14.5 and
/// 14.6's fs_usage don't have it.)
///
/// One file per user, /etc/sudoers.d/ssd-monitor-<uid>. Added and removed with macOS's administrator password
/// dialog (`do shell script … with administrator privileges`, through osascript so the app never waits on it),
/// so the app never sees the password. sudo's whole configuration must pass visudo before anything changes; the
/// new file is checked on its own, then swapped in with one rename, and the whole configuration is checked again
/// (the change is undone if it fails). One change at a time (AppController).
enum SudoRule {
    static let traceSeconds = 30
    static let sudoTimeout = 40
    static let command = ["/usr/bin/fs_usage", "-w", "-f", "diskio", "-t", String(traceSeconds)]
    /// `-k`: ignore any cached sudo login, so only the rule can let it run; `-n`: never ask for a password;
    /// `-T`: sudo's own time limit, whichever sudoers rule matches (the rule's Defaults line allows it for
    /// fs_usage only). With a time limit sudo always stays as the supervisor.
    static let sudoArguments = ["-k", "-n", "-T", String(sudoTimeout)] + command
    static var file: String { "/private/etc/sudoers.d/ssd-monitor-\(getuid())" }

    enum Outcome: Equatable { case done, cancelled, failed(String) }

    /// This user's file is there and not empty (Remove leaves it empty: see removeScript), or can't be looked
    /// at (a /etc/sudoers.d only root may enter): then sudo decides when fs_usage starts. Its contents are root's
    /// only; whether sudo accepts it shows when fs_usage starts, and AppController remembers that.
    static var isInstalled: Bool {
        var info = stat()
        if stat(file, &info) == 0 { return info.st_size > 0 }
        guard errno == EACCES || errno == EPERM else { return false }
        return lastChange ?? true   // can't look: what this app last did to it, else maybe there
    }

    /// The app's own last successful change in this run (true = added, false = removed), for when the folder
    /// can't be looked into.
    nonisolated(unsafe) static var lastChange: Bool?

    /// By user ID: a user name could be a sudoers keyword (an account named ALL would match everyone).
    static var ruleLine: String {
        "#\(getuid()) ALL=(root) TIMEOUT=\(sudoTimeout) NOPASSWD: \(command.joined(separator: " "))"
    }

    /// Lets the app give fs_usage (and only fs_usage) a time limit of its own with `sudo -T`.
    static var defaultsLine: String { "Defaults!\(command[0]) user_command_timeouts" }

    /// No account name in it: renaming the account keeps the user ID, and the file must still be the app's own.
    private static let comment = "# SSD Monitor: lets its Statistics window list the programs that use the SSD."

    private static let precheck = "if ! /usr/sbin/visudo -cq; then echo 'sudo settings do not pass visudo even "
        + "before the change, so nothing was changed' >&2; exit 1; fi"
    private static let dir = "/private/etc/sudoers.d"

    /// The file must be exactly what this app writes (or empty) before it is replaced or emptied: anything an
    /// administrator changed, added, removed or reordered there is never thrown away. The app's contents are
    /// written to a temp file and compared byte for byte.
    private static var ownedCheck: String {
        let f = file
        return "e=$(/usr/bin/mktemp \(dir)/.ssd-monitor-own.XXXXXX); " + contents("$e") + "; "
            + "if [ -s \(f) ] && ! /usr/bin/cmp -s \(f) \"$e\"; then /bin/rm -f \"$e\"; "
            + "echo '\(f) is not what SSD Monitor wrote, so it was left alone' >&2; exit 1; fi; /bin/rm -f \"$e\""
    }

    /// The shell command that writes the file's contents into `target`.
    private static func contents(_ target: String) -> String {
        "/usr/bin/printf '%s\\n' '\(comment)' '\(defaultsLine)' '\(ruleLine)' > \"\(target)\""
    }

    /// Identifies the file's current state (inode, size, change time) without reading it: a change through the
    /// password dialog that went through, even if its osascript was stopped before it could say so.
    static func signature() -> String {
        var info = stat()
        guard stat(file, &info) == 0 else { return errno == ENOENT ? "none" : "unknown" }
        return "\(info.st_ino):\(info.st_size):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    /// Written to a temp name (sudo ignores names with a dot), checked on its own, then renamed into place over
    /// any earlier copy (kept aside under a unique name meanwhile); if sudo's whole configuration then fails,
    /// the earlier copy comes back, or the file goes. A copy kept aside stays if putting it back fails.
    static func installScript() -> String {
        let f = file
        return [
            "set -e",
            "umask 077",
            precheck,
            ownedCheck,
            "t=$(/usr/bin/mktemp \(dir)/.ssd-monitor.XXXXXX)",
            "trap '/bin/rm -f \"$t\"' EXIT",
            contents("$t"),
            "/usr/sbin/chown root:wheel \"$t\"",
            "/bin/chmod 0440 \"$t\"",
            "/usr/sbin/visudo -cq -O -P -f \"$t\"",   // -O -P: owner and mode too
            "b=",
            "if [ -e \(f) ]; then b=$(/usr/bin/mktemp \(dir)/.ssd-monitor-old.XXXXXX); /bin/cp -p \(f) \"$b\"; fi",
            "/bin/mv -f \"$t\" \(f)",
            "if ! /usr/sbin/visudo -cq; then if [ -n \"$b\" ]; then /bin/mv -f \"$b\" \(f); else /bin/rm -f \(f); fi; "
                + "echo 'sudo settings did not pass visudo with the rule, so the change was undone' >&2; exit 1; fi",
            "if [ -n \"$b\" ]; then /bin/rm -f \"$b\"; fi",
        ].joined(separator: "; ")
    }

    /// Removing empties the file with one rename instead of deleting it: an empty sudoers file grants nothing
    /// and is valid, and a file that something else names (an explicit include, at any depth) can't go missing.
    /// The earlier contents are kept aside until the configuration passes, and stay if putting them back fails.
    static func removeScript() -> String {
        let f = file
        return [
            "set -e",
            "umask 077",
            "[ -s \(f) ] || exit 0",
            precheck,
            ownedCheck,
            "t=$(/usr/bin/mktemp \(dir)/.ssd-monitor.XXXXXX)",
            "trap '/bin/rm -f \"$t\"' EXIT",
            "/usr/sbin/chown root:wheel \"$t\"",
            "/bin/chmod 0440 \"$t\"",
            "/usr/sbin/visudo -cq -O -P -f \"$t\"",   // -O -P: owner and mode too
            "b=$(/usr/bin/mktemp \(dir)/.ssd-monitor-old.XXXXXX)",
            "/bin/cp -p \(f) \"$b\"",
            "/bin/mv -f \"$t\" \(f)",
            "if ! /usr/sbin/visudo -cq; then /bin/mv -f \"$b\" \(f); "
                + "echo 'sudo settings did not pass visudo without the rule, so it was put back' >&2; exit 1; fi",
            "/bin/rm -f \"$b\"",
        ].joined(separator: "; ")
    }

    static let installPrompt = "SSD Monitor wants to add a sudo rule so its Statistics window can list the programs that read and write the SSD."
    static let removePrompt = "SSD Monitor wants to remove its sudo rule for fs_usage."
}

/// One command run as root behind macOS's password dialog, through osascript.
/// `completion` reports the outcome to whoever asked (dropped by `cancel()`); `onExit` always runs once
/// osascript has exited, even after a cancel, since the change may have happened anyway.
@MainActor
final class AdminTask {
    private var child: ChildProcess?
    private let errors = ScratchOutput()
    private var completion: (@MainActor (SudoRule.Outcome) -> Void)?
    private var onExit: (@MainActor (SudoRule.Outcome) -> Void)?
    private let label: String

    init(shell: String, prompt: String, label: String, onExit: @escaping @MainActor (SudoRule.Outcome) -> Void,
         completion: @escaping @MainActor (SudoRule.Outcome) -> Void) {
        self.label = label
        self.completion = completion
        self.onExit = onExit
        let apple = "do shell script \(AdminTask.literal(shell)) with prompt \(AdminTask.literal(prompt)) with administrator privileges"
        Log.write("\(label): asking for the password")
        let null = open("/dev/null", O_WRONLY)
        defer { if null >= 0 { close(null) } }
        guard let errors, null >= 0 else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.exited(-1, launchError: "could not create a temp file") } }
            return
        }
        // Holds the task until osascript has exited, so onExit always runs.
        let spawned = ChildProcess.spawn("/usr/bin/osascript", ["-e", apple], stdout: null,
                                         stderr: errors.handle.fileDescriptor) { code in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.exited(code) } }
        }
        switch spawned {
        case .success(let child): self.child = child
        case .failure(let error):
            let why = "could not start osascript: \(error.localizedDescription)"
            DispatchQueue.main.async { MainActor.assumeIsolated { self.exited(-1, launchError: why) } }
        }
    }

    /// For quitting: end osascript now (SIGTERM, then SIGKILL a moment later if it is still there).
    func killNow() {
        guard let child, child.isRunning else { return }
        child.signal(SIGTERM)
        usleep(200_000)
        child.signal(SIGKILL)   // a no-op once it has exited
    }

    /// Close the password dialog (if it is still up) and stop reporting to the asker.
    func cancel() {
        guard completion != nil else { return }
        completion = nil
        if let child, child.isRunning {
            child.signal(SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { child.signal(SIGKILL) }   // a no-op once gone
        }
        Log.write("\(label): cancelled")
    }

    private func exited(_ status: Int32, launchError: String? = nil) {
        let text = errors?.text() ?? ""
        let outcome: SudoRule.Outcome
        if let launchError {
            outcome = .failed(launchError)
        } else if status == 0 {
            outcome = .done
        } else if text.contains("(-128)") {
            outcome = .cancelled   // the user pressed Cancel
        } else {
            // "0:120: execution error: <message> (1)"
            var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = message.range(of: "execution error: ") { message = String(message[range.upperBound...]) }
            if let range = message.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { message.removeSubrange(range) }
            outcome = .failed(message.isEmpty ? "exit status \(status)" : message)
        }
        switch outcome {
        case .done: Log.write("\(label): done")
        case .cancelled: Log.write("\(label): cancelled at the password dialog")
        case .failed(let why): Log.write("\(label) failed: \(why)")
        }
        let completion = self.completion
        self.completion = nil
        let onExit = self.onExit
        self.onExit = nil
        child = nil
        completion?(outcome)
        onExit?(outcome)
    }

    /// An AppleScript string literal.
    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
