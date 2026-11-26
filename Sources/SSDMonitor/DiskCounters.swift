import Foundation
import IOKit

/// The SSD's byte counters, which the kernel keeps from the moment the SSD is attached: one pair per APFS
/// volume (what the volume read from and wrote to the disk; reads served from memory don't count) and one pair
/// for the whole disk (its IOBlockStorageDriver, the numbers `iostat` shows). Read only while the Statistics
/// window is open; each read is a registry lookup, no disk access.
final class DiskCounters {
    struct Bytes { var read: UInt64; var written: UInt64 }
    struct Reading {
        let disk: Bytes?
        let volumes: [String: Bytes]   // by volume name
    }

    private var volumes: [(name: String, entry: io_registry_entry_t)] = []
    private var driver: io_registry_entry_t = 0
    /// The SSD's own devices besides the volumes: the whole disk ("disk4") and the APFS container ("disk5").
    /// fs_usage names one of these (or a partition) for I/O that no volume owns.
    private(set) var wholeDisk: String?
    private(set) var container: String?
    /// The disk driver's registry entry ID: the same for as long as this attachment lasts, new after a replug.
    private(set) var diskEntryID: UInt64?

    /// `devices`: the setup's volumes that are attached, with their BSD names ("disk5s1").
    init(devices: [(name: String, bsd: String)]) {
        for device in devices {
            guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, device.bsd) else { continue }
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, match as CFDictionary)
            if entry != 0 { volumes.append((device.name, entry)) }
        }
        if let first = volumes.first?.entry { findDisk(above: first) }
    }

    deinit {
        for volume in volumes { IOObjectRelease(volume.entry) }
        if driver != 0 { IOObjectRelease(driver) }
    }

    /// The registry entry ID of the disk a volume is on (see `diskEntryID`).
    static func diskEntryID(volumeBSD: String) -> UInt64? {
        DiskCounters(devices: [("", volumeBSD)]).diskEntryID
    }

    func read() -> Reading {
        var byVolume: [String: Bytes] = [:]
        for volume in volumes {
            guard let stats = DiskCounters.property(volume.entry, "Statistics") as? NSDictionary,
                  let read = stats["Bytes read from block device"] as? NSNumber,
                  let written = stats["Bytes written to block device"] as? NSNumber else { continue }
            byVolume[volume.name] = Bytes(read: read.uint64Value, written: written.uint64Value)
        }
        var disk: Bytes?
        if driver != 0, let stats = DiskCounters.property(driver, "Statistics") as? NSDictionary,
           let read = stats["Bytes (Read)"] as? NSNumber, let written = stats["Bytes (Write)"] as? NSNumber {
            disk = Bytes(read: read.uint64Value, written: written.uint64Value)
        }
        return Reading(disk: disk, volumes: byVolume)
    }

    /// Up the registry from a volume: the APFS container's disk, the partition it lives in, the whole disk,
    /// then the disk's driver, which holds the counters for everything on the SSD.
    private func findDisk(above entry: io_registry_entry_t) {
        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, options, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var lastMedia: String?
        while case let parent = IOIteratorNext(iterator), parent != 0 {
            if IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0 {
                driver = parent   // kept until deinit
                wholeDisk = lastMedia
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS { diskEntryID = id }
                return
            }
            if IOObjectConformsTo(parent, "IOMedia") != 0, let bsd = DiskCounters.property(parent, "BSD Name") as? String {
                if container == nil { container = bsd }
                lastMedia = bsd
            }
            IOObjectRelease(parent)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
