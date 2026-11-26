import Foundation
import Darwin

/// A child process started with posix_spawn, for the commands that may need stopping (fs_usage through sudo,
/// osascript behind a password dialog):
/// - its own session (no controlling terminal), only stdin (/dev/null), stdout and stderr open, working folder
///   "/", default signal handling and nothing blocked (the app ignores SIGTERM itself; a child would inherit it);
/// - a background thread waits for it (blocking, so the exit can't be missed). It sees the exit without reaping
///   it, makes the process ID unsignalable under a lock, then reaps it. `signal` sends under the same lock, so it
///   can never reach a process that got the ID afterwards.
final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?   // under lock, until the exit is seen

    /// `onExit` runs on the waiting thread, with the exit status (128 + signal if it was killed by one).
    static func spawn(_ path: String, _ arguments: [String], stdout: Int32, stderr: Int32,
                      onExit: @escaping @Sendable (Int32) -> Void) -> Result<ChildProcess, Error> {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir_np(&actions, "/")   // never hold an SSD folder open
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard result == 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)) }
        let child = ChildProcess()
        child.pid = pid
        Thread.detachNewThread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            child.lock.lock()
            child.pid = nil
            child.lock.unlock()
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            let signal = status & 0x7f
            onExit(reaped == pid ? (signal == 0 ? (status >> 8) & 0xff : 128 + signal) : -1)
        }
        return .success(child)
    }

    /// Sends `signal` if the process hasn't exited. Returns 0, or the errno (ESRCH once it has exited).
    @discardableResult
    func signal(_ signal: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let pid else { return ESRCH }
        return kill(pid, signal) == 0 ? 0 : errno
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid != nil
    }
}
