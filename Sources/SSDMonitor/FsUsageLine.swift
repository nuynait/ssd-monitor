import Foundation

/// One disk I/O line of `fs_usage -w -f diskio`, as Apple's fs_usage.c prints it (wide mode):
///
///     15:04:37.125890  RdData[AT1]       D=0x00a3d6e8  B=0x4000   /dev/disk5s1  /path/of/the/file   0.000304 W mds_stores.1234567
///
/// time, call, disk block, byte count (hex), device, path (padded, may be empty or contain spaces), elapsed
/// time, "W", then the program's name and the thread id.
struct FsUsageLine {
    let device: String      // "disk5s1"
    let program: String
    let isRead: Bool
    let bytes: UInt64
    /// The file's path when fs_usage printed one (data I/O; not metadata). Only for telling which volume an
    /// I/O on the SSD's shared device belongs to; never kept.
    let path: String
    /// The path filled its column, so fs_usage may have kept only its end (it pads shorter ones with spaces).
    let pathMayBeCut: Bool

    /// The elapsed time and " W" (or two spaces) just before the program name. A path can contain anything,
    /// so the last match counts.
    private static let elapsed = try! NSRegularExpression(pattern: #"(\s+)(\d+)\.\d{6}(?: W|  ) "#)

    /// Fields in fs_usage's order: time, call, "D=0x<block>", "B=0x<bytes>" (a failed I/O has "[errno]" there
    /// and is skipped), "/dev/<device>". `wanted` sees the device name first, so lines for other disks cost no
    /// string work past it.
    static func parse(_ line: ArraySlice<UInt8>, wanted: (String) -> Bool) -> FsUsageLine? {
        var i = line.startIndex
        let end = line.endIndex
        let space = UInt8(ascii: " ")
        func skipSpaces() { while i < end, line[i] == space { i += 1 } }
        func expect(_ text: String) -> Bool {
            for byte in text.utf8 {
                guard i < end, line[i] == byte else { return false }
                i += 1
            }
            return true
        }
        func hex() -> UInt64? {
            var value: UInt64 = 0
            var digits = 0
            while i < end, let digit = hexValue(line[i]) {
                guard digits < 16 else { return nil }
                value = value << 4 | UInt64(digit)
                i += 1
                digits += 1
            }
            return digits > 0 ? value : nil
        }

        // The time, "HH:MM:SS.uuuuuu": anything else is not the start of a record (a path with a line break in it
        // splits its record; both halves are dropped).
        for (offset, kind) in "dd:dd:dd.dddddd ".utf8.enumerated() {
            guard i + offset < end else { return nil }
            let byte = line[i + offset]
            if kind == UInt8(ascii: "d") ? !(48...57).contains(byte) : byte != kind { return nil }
        }
        i += 16
        skipSpaces()
        let callStart = i
        while i < end, line[i] != space, line[i] != UInt8(ascii: "[") { i += 1 }
        let call = String(decoding: line[callStart..<i], as: UTF8.self)
        let isRead: Bool
        if call.hasPrefix("Rd") || call == "PgIn" { isRead = true }
        else if call.hasPrefix("Wr") || call == "PgOut" { isRead = false }
        else { return nil }
        while i < end, line[i] != space { i += 1 }            // the call's flags, "[AT1]"
        skipSpaces()
        guard expect("D=0x"), hex() != nil else { return nil }
        skipSpaces()
        guard expect("B=0x"), let bytes = hex(), bytes <= 1 << 32 else { return nil }   // one I/O, not 4 GB
        skipSpaces()
        guard expect("/dev/") else { return nil }
        let deviceStart = i
        while i < end, line[i] != space { i += 1 }
        let device = String(decoding: line[deviceStart..<i], as: UTF8.self)
        guard !device.isEmpty, wanted(device) else { return nil }

        let rest = String(decoding: line[i..<end], as: UTF8.self)
        guard let marker = elapsed.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)).last,
              let range = Range(marker.range, in: rest),
              let spaces = Range(marker.range(at: 1), in: rest),
              let seconds = Range(marker.range(at: 2), in: rest) else { return nil }
        let path = rest[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        // fs_usage prints the path as " <path> " padded to its column (a cut path keeps the trailing space),
        // then " " and "%3llu" (padded to 3). What is left over is the path's own padding: none means it filled
        // the column and may have been cut.
        let padding = rest[spaces].count - 2 - max(0, 3 - rest[seconds].count)
        // "<program>.<thread id>": the name may itself contain dots and spaces (even leading ones: the separator
        // space is already part of the marker).
        var program = String(rest[range.upperBound...])
        while let last = program.last, last == "\r" || last == "\n" || last == " " { program.removeLast() }
        if let dot = program.lastIndex(of: "."), program.index(after: dot) < program.endIndex,
           program[program.index(after: dot)...].allSatisfy(\.isNumber) {
            program = String(program[..<dot])
        }
        return FsUsageLine(device: device, program: program.isEmpty ? "?" : program, isRead: isRead, bytes: bytes,
                           path: path, pathMayBeCut: !path.isEmpty && padding <= 0)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
