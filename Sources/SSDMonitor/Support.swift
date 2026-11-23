import Foundation

/// One SSD volume: its name, APFS volume UUID, and where it must be mounted.
/// The list comes from `ssd-resume --step list` (`helpers/ssd-volumes.sh` in this repo).
struct Volume: Equatable {
    let name: String
    let uuid: String
    let path: String
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Both scripts live on the Mac's own disk, so they work while the SSD is gone.
    static let resume = home + "/Local/bin/ssd-resume"
    static let off = home + "/Local/bin/ssd-off"
    /// Left by `ssd-off` (or the app's own eject) when the SSD goes away on purpose.
    static let plannedMarker = home + "/Local/ssd/planned-unplug"

    /// The scripts carry "ssd-monitor-protocol: 1" in their header. Older ones don't know `--step` and would
    /// run their whole routine instead, so the app checks the text before it runs anything.
    static func speaksProtocol(_ path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.contains("ssd-monitor-protocol: 1")
    }

    static func tilde(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Append-only log, written on state changes only: ~/Library/Logs/SSD Monitor/ssd-monitor.log.
/// Rotated at 512 KB (one old file kept).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SSD Monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssd-monitor.log")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = Data("\(stamp.string(from: Date())) \(message)\n".utf8)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}

/// Decimal gigabytes, as Finder shows them.
func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.0f GB", Double(bytes) / 1_000_000_000)
}
