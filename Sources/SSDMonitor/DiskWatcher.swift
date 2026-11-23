import Foundation
import DiskArbitration

/// Tracks the SSD's volumes through DiskArbitration, and listens to the kernel's mount events. macOS calls
/// back when a disk appears, disappears or changes (mounted, unmounted, moved), and the kernel when any
/// file system is mounted, unmounted or changed in place (e.g. switched to read-only); nothing is polled.
/// Only disks whose volume UUID is one of the SSD's are kept. Runs on the main queue. Disk descriptions are
/// read only inside DiskArbitration's callbacks, where they come with the event: the app never waits on the
/// DiskArbitration daemon.
final class DiskWatcher {
    struct Disk {
        let bsdName: String
        let uuid: String
        var volumePath: String?
    }

    private let uuids: Set<String>
    private var session: DASession?
    private var mountEvents: DispatchSourceRead?
    private(set) var disks: [String: Disk] = [:]   // by BSD name, e.g. disk5s1
    /// The last of the SSD's disks disappeared since `takeAllGone()` was last asked: a disconnect, even if
    /// the SSD is back before the app looks.
    private var allGone = false
    var onChange: (() -> Void)?

    init(uuids: Set<String>) {
        self.uuids = Set(uuids.map { $0.uppercased() })
    }

    func start() {
        watchMountEvents()
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            Log.write("DiskArbitration: no session")
            return
        }
        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            DiskWatcher.from(context)?.update(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            DiskWatcher.from(context)?.remove(disk)
        }, context)
        // Description changes only for the mount path (mounted, unmounted, moved): other keys of other disks
        // don't call back at all.
        DARegisterDiskDescriptionChangedCallback(session, nil, [kDADiskDescriptionVolumePathKey] as CFArray, { disk, _, context in
            DiskWatcher.from(context)?.update(disk)
        }, context)
    }

    func disk(uuid: String) -> Disk? {
        let key = uuid.uppercased()
        return disks.values.first { $0.uuid == key }
    }

    func takeAllGone() -> Bool {
        defer { allGone = false }
        return allGone
    }

    // MARK: - private

    /// The kernel's file-system events (EVFILT_FS) through a kqueue. Quiet: they fire only when something
    /// is mounted, unmounted or updated in place, anywhere on the Mac (measured: 2 events for one
    /// unmount-and-mount, none otherwise). The app re-checks the mount table on each.
    private func watchMountEvents() {
        let kq = kqueue()
        guard kq >= 0 else { Log.write("kqueue failed: \(errno)"); return }
        var change = kevent(ident: 0, filter: Int16(EVFILT_FS), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(VQ_MOUNT | VQ_UNMOUNT | VQ_UPDATE | VQ_DEAD), data: 0, udata: nil)
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else {
            Log.write("EVFILT_FS failed: \(errno)")
            close(kq)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: .main)
        source.setEventHandler { [weak self] in
            var event = kevent()
            var now = timespec(tv_sec: 0, tv_nsec: 0)
            while kevent(kq, nil, 0, &event, 1, &now) > 0 {}   // drain; what changed is read from the mount table
            self?.onChange?()
        }
        source.setCancelHandler { close(kq) }
        source.resume()
        mountEvents = source
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> DiskWatcher? {
        guard let context else { return nil }
        return Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue()
    }

    private func update(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        guard let description = DADiskCopyDescription(disk) as NSDictionary?,
              let uuid = DiskWatcher.uuidString(description[kDADiskDescriptionVolumeUUIDKey as String]),
              uuids.contains(uuid) else {
            drop(bsd)
            return
        }
        let path = (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
        let new = Disk(bsdName: bsd, uuid: uuid, volumePath: path)
        let old = disks[bsd]
        disks[bsd] = new
        if old?.volumePath != new.volumePath || old == nil { onChange?() }
    }

    private func remove(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        drop(bsd)
    }

    private func drop(_ bsd: String) {
        guard disks.removeValue(forKey: bsd) != nil else { return }
        if disks.isEmpty { allGone = true }
        onChange?()
    }

    private static func uuidString(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        let uuid = unsafeBitCast(value as CFTypeRef, to: CFUUID.self)
        return (CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?)?.uppercased()
    }
}

enum VolumeState: Equatable {
    case ok
    case absent                 // not on the bus: the SSD (or this volume) is not attached
    case notMounted
    case elsewhere(String)      // mounted, but not at its path (e.g. /Volumes/Repo 1)
    case readOnly

    var short: String {
        switch self {
        case .ok: return "ok"
        case .absent: return "not attached"
        case .notMounted: return "not mounted"
        case .elsewhere(let path): return "mounted at \(path)"
        case .readOnly: return "read-only"
        }
    }
}

struct VolumeStatus {
    let volume: Volume
    let state: VolumeState
}

/// The SSD's state at one moment. Built from DiskArbitration's records plus one `getfsstat` call
/// (the kernel's cached mount table and space figures: never blocks, even on a dying disk).
struct Health {
    let volumes: [VolumeStatus]
    /// At least one of the SSD's volumes is on the bus.
    let connected: Bool
    /// Free space on the SSD (its volumes share one container), while any of them is mounted.
    let freeBytes: UInt64?
    /// Any of the SSD's volumes is in the mount table, wherever it is mounted.
    var anyMounted: Bool { freeBytes != nil }

    static let empty = Health(volumes: [], connected: false, freeBytes: nil)

    var allOK: Bool { !volumes.isEmpty && volumes.allSatisfy { $0.state == .ok } }
    var okCount: Int { volumes.filter { $0.state == .ok }.count }
    var bad: [VolumeStatus] { volumes.filter { $0.state != .ok } }
    /// Identifies the current problem, so a dismissed alarm is not shown again for the same thing.
    var issueKey: String { bad.map { "\($0.volume.name):\($0.state.short)" }.joined(separator: ",") }

    static func evaluate(_ volumes: [Volume], _ watcher: DiskWatcher) -> Health {
        // The SSD's devices DiskArbitration knows ("/dev/disk5s1" -> which volume).
        var wanted: [String: Int] = [:]
        var attached = [Bool](repeating: false, count: volumes.count)
        for (i, volume) in volumes.enumerated() {
            if let disk = watcher.disk(uuid: volume.uuid) {
                attached[i] = true
                wanted["/dev/\(disk.bsdName)"] = i
            }
        }
        let mounts = mountTable(for: wanted)
        var statuses: [VolumeStatus] = []
        statuses.reserveCapacity(volumes.count)
        var free: UInt64?
        for (i, volume) in volumes.enumerated() {
            let state: VolumeState
            if !attached[i] {
                state = .absent
            } else if let mount = mounts[i] {
                if free == nil { free = mount.free }
                state = mount.path != volume.path ? .elsewhere(mount.path) : (mount.readOnly ? .readOnly : .ok)
            } else {
                state = .notMounted
            }
            statuses.append(VolumeStatus(volume: volume, state: state))
        }
        return Health(volumes: statuses, connected: attached.contains(true), freeBytes: free)
    }

    /// Where the wanted devices are mounted, from the kernel's cached mount table (MNT_NOWAIT: no file system
    /// is asked, so it can't block): volume index -> (mount point, read-only, free bytes). Only entries whose
    /// device is a disk are turned into strings, and only the wanted ones are kept. The kernel keeps the space
    /// figures current (measured: a 2 GB write showed up at once).
    private static func mountTable(for wanted: [String: Int]) -> [Int: (path: String, readOnly: Bool, free: UInt64)] {
        guard !wanted.isEmpty else { return [:] }
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [:] }
        var stats = Array<statfs>(repeating: statfs(), count: Int(count) + 8)
        let got = getfsstat(&stats, Int32(stats.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard got > 0 else { return [:] }
        var found: [Int: (path: String, readOnly: Bool, free: UInt64)] = [:]
        for var s in stats.prefix(Int(got)) {
            let from: String? = withUnsafePointer(to: &s.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    strncmp($0, "/dev/disk", 9) == 0 ? String(cString: $0) : nil
                }
            }
            guard let from, let index = wanted[from] else { continue }
            let on = withUnsafePointer(to: &s.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            found[index] = (on, s.f_flags & UInt32(MNT_RDONLY) != 0, UInt64(s.f_bavail) * UInt64(s.f_bsize))
        }
        return found
    }
}
