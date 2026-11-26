import AppKit

/// The Statistics window: how fast the SSD reads and writes, now and over the last 10 minutes, per volume, and
/// which programs do it. Nothing of it runs while it is closed: opening it starts a 1-second timer that reads the
/// kernel's byte counters (DiskCounters) and, through the sudo rule, fs_usage for the program list
/// (ProgramTrace). Closing it stops both and drops what was collected, so it starts empty each time.
///
/// Rows: the setup's volumes, then "APFS shared", the SSD's traffic that no volume owns (APFS's own
/// checkpoints and space maps): the whole disk's counters minus the volumes'. The rows always add up to the
/// whole disk's own counters, so the totals are simply the checked rows.
@MainActor
final class StatsWindow: NSObject, NSWindowDelegate {
    static let span: TimeInterval = 600       // the graph's 10 minutes, one bar per second
    static let programSeconds = 3             // the program list averages the last 3 whole seconds
    static let shownVolumes = 10              // the volume list is this many rows tall; more scroll
    static let sharedName = "APFS shared"

    struct Sample {
        let time: TimeInterval    // system uptime at the end of the interval it covers
        let seconds: TimeInterval // that interval: about 1 s, longer if a reading came late
        let wall: Date            // the wall clock at its end
        let read: [Double]        // bytes per second, per row
        let write: [Double]

        /// The checked rows together.
        func total(_ checked: [Bool], read wantRead: Bool) -> Double {
            let values = wantRead ? read : write
            var sum = 0.0
            for (row, value) in values.enumerated() where row < checked.count && checked[row] { sum += value }
            return sum
        }
    }
    private struct ProgramKey: Hashable { let row: Int; let program: String }

    private unowned let controller: AppController
    private var window: NSWindow?
    private let volumes: [Volume]
    private let rowNames: [String]
    private var checked: [Bool]
    private var deviceKey: String?            // which attachment of which devices the counters were built for
    private var mountKey: String?             // where the volumes were mounted when the trace was told
    private var attached = Set<String>()      // volume names on the bus now
    private var liveSince: TimeInterval = 0   // samples before this don't show as current (a change, a gap)
    private var programsSince: TimeInterval = 0   // program traffic before this is dropped (a device change, a sleep)
    private var frozenAt: Date?               // when the graph stopped moving: the last moment the SSD was seen
    private var frozen = false                // the SSD is away (the axis then says so)
    private var graphRightWall: Date?         // the wall clock at graphRight
    private var samples: [Sample] = []
    private var counters: DiskCounters?
    private var devices: [(name: String, bsd: String, mountedAt: String?)] = []
    private var countersIncomplete = false    // a counter was missing: look the registry entries up again
    private var graphRight: TimeInterval?     // the graph's right edge: the clock while connected, then frozen
    private var baseline: (time: TimeInterval, reading: DiskCounters.Reading)?
    private var timer: Timer?
    private var trace: ProgramTrace?
    private var traceState: ProgramTrace.State?
    private var traceDevices = ProgramTrace.Devices()
    private var ruleSignature = ""            // the rule file as it was when the trace started
    private var closed = false                // stopped for good: nothing may start again
    private var buckets: [(second: Int, bytes: [ProgramKey: (read: UInt64, written: UInt64)])] = []
    var onClose: (() -> Void)?

    private let axisLeft = UI.label("10 minutes ago", size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let axisRight = UI.label("now", size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let readValue = UI.number(size: 24, weight: .medium)
    private let writeValue = UI.number(size: 24, weight: .medium)
    private let graph = GraphView()
    private let volumeTable = StatTable(columns: [
        .init(title: "Volume", width: 150, kind: .check),
        .init(title: "Read", width: 78, kind: .number),
        .init(title: "Write", width: 78, kind: .number),
        .init(title: "Max read", width: 78, kind: .number, tooltip: "The highest read speed since the window opened"),
        .init(title: "Max write", width: 78, kind: .number, tooltip: "The highest write speed since the window opened"),
    ], flexible: 0)
    private var volumeText: [[String]] = []   // per row: read, write, max read, max write
    private let liveTable = StatTable(columns: [
        .init(title: "Program", width: 150),
        .init(title: "Read", width: 78, kind: .number),
        .init(title: "Write", width: 78, kind: .number),
    ], flexible: 0)
    private var liveRows: [(name: String, read: Double, write: Double)] = []
    private let liveWarning = UI.label("May be incomplete", size: NSFont.smallSystemFontSize, color: .systemOrange)
    private let historyTable = StatTable(columns: [
        .init(title: "Program", width: 220),
        .init(title: "Volume", width: 150),
        .init(title: "Read", width: 86, kind: .number),
        .init(title: "Write", width: 86, kind: .number),
        .init(title: "Reads and writes", width: 120, kind: .bar,
              tooltip: "Each program's reads (pink) and writes (blue), next to the busiest program's"),
    ], flexible: 4, alternating: false)
    private struct HistoryLine {
        let name: String      // the program, on its own line; empty on the lines of its volumes
        let volume: String
        let read: UInt64
        let written: UInt64
        let total: Bool       // the program's own line: its totals
        let band: Bool        // every other program's lines are shaded
    }
    private var historyLines: [HistoryLine] = []
    private var historyHidden = 0             // programs with traffic that didn't fit
    private var historyScale = 1.0            // the busiest program's bytes: the full bar
    // Since the window opened (user decision: nothing kept after it closes).
    private var rowMax: [(read: Double, write: Double)]
    private var totalMax: (read: Double, readAt: Date?, write: Double, writeAt: Date?) = (0, nil, 0, nil)
    private var history: [String: [Int: (read: UInt64, written: UInt64)]] = [:]   // program -> row -> bytes
    private var historySince: (clock: TimeInterval, wall: Date)?   // when the program list first traced
    private var historyGaps: [String] = []    // why some traffic may be missing from the history
    private var historyDirty = true           // the history or the checkboxes changed since it was shown
    private var rankTotals: [String: UInt64] = [:]   // each program's bytes on the checked rows
    private var rankOrder: [String] = []      // programs, busiest first
    private var rankChanged = Set<String>()   // programs whose total changed since the ranking was updated
    private var rankRebuild = true            // the checkboxes changed: rank everything again
    private var stoppedBeforeHistory = false  // a trace stopped before the history's first data arrived
    private var openedAt = Date()
    private var lastDisk: DiskCounters.Bytes?   // the whole disk's counters: since it was plugged in
    private let maxReadLabel = UI.label(size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let maxWriteLabel = UI.label(size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let totalsLabel = UI.label(size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let historyTitle = UI.label("Programs since the window opened", weight: .semibold)
    private let historyGapNote = UI.label(size: NSFont.smallSystemFontSize, color: .systemOrange)
    static let historyLines = 300
    static let rankedPrograms = 150   // at least two lines each: all that 300 lines can show
    private var openedAtClock: TimeInterval?
    private let programSpinner = UI.spinner()
    private lazy var setupButton = UI.button("Set Up…", self, #selector(setUpRule))
    private lazy var retryButton = UI.button("Try Again", self, #selector(retryTrace))

    /// Keeps running while the Mac sleeps, so the graph shows a sleep as a gap.
    private static var uptime: TimeInterval { ProgramTrace.clock }
    /// A reading this long after the one before (a sleep, a stall) starts afresh: a gap, not an average.
    private static let longestInterval: TimeInterval = 5

    init(controller: AppController, volumes: [Volume]) {
        self.controller = controller
        self.volumes = volumes
        rowNames = volumes.map(\.name) + [StatsWindow.sharedName]
        checked = Array(repeating: true, count: rowNames.count)
        rowMax = Array(repeating: (0, 0), count: rowNames.count)
        super.init()
        volumeTable.content = { [weak self] row, column in self?.volumeCell(row, column) ?? .init() }
        volumeTable.onCheck = { [weak self] row, on in self?.setChecked(row, on) }
        liveTable.content = { [weak self] row, column in self?.liveCell(row, column) ?? .init() }
        historyTable.content = { [weak self] row, column in self?.historyCell(row, column) ?? .init() }
        historyTable.shaded = { [weak self] row in
            guard let self, self.historyLines.indices.contains(row) else { return false }
            return self.historyLines[row].band
        }
    }

    func show() {
        if window == nil {
            window = build()
            start()
        }
        if let window { UI.show(window) }
    }

    /// The setup is about to add the rule and check it with a trace of its own: let go of the kernel's one
    /// trace until it is done (sudoRuleChanged() follows).
    func holdTrace() {
        guard !closed, trace != nil || traceState == .starting else { return }
        stopTrace()
        traceState = .starting
        renderPrograms(now: StatsWindow.uptime)
    }

    /// The SSD's disks or mounts may have changed: look now, not only at the next tick.
    func checkDevices() {
        guard !closed else { return }
        _ = updateDevices(now: StatsWindow.uptime)
    }

    /// The sudo rule may have been added or removed.
    func sudoRuleChanged() {
        guard window != nil, !closed else { return }
        if SudoRule.isInstalled {
            switch traceState {
            case nil, .needsSetup?, .failed?: startTrace()
            case .starting?: if trace == nil { startTrace() }   // it waited for the setup's check
            case .running?: break
            }
        } else {
            stopTrace()
            traceState = .needsSetup
            renderPrograms(now: StatsWindow.uptime)
        }
    }

    /// Stop reading anything and drop what was collected. Closing the window does this.
    func stop() {
        closed = true
        timer?.invalidate()
        timer = nil
        stopTrace()
        counters = nil
        baseline = nil
        samples = []
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        Log.write("statistics: closed")
        window?.contentView = nil
        window = nil
        onClose?()
        onClose = nil
    }

    // MARK: - reading

    private func start() {
        Log.write("statistics: opened")
        openedAt = Date()
        openedAtClock = StatsWindow.uptime
        tick()   // the first reading is only the starting point; the first speed comes a second later
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)   // also while a menu is open or the window is resized
        self.timer = timer
        startTrace()
    }

    /// The SSD's disks came or went (unplugged, back, a volume attached or detached; not just any mount on the
    /// Mac): new counters, a new starting point, and a new trace, so nothing it had read yet counts for the new
    /// attachment.
    private func rebuildCounters(_ devices: [(name: String, bsd: String, mountedAt: String?)], key: String,
                                 now: TimeInterval) {
        let first = deviceKey == nil
        deviceKey = key
        lastDisk = nil   // the totals belong to the attachment that is gone
        self.devices = devices
        countersIncomplete = false
        attached = Set(devices.map(\.name))
        baseline = nil
        liveSince = now
        programsSince = now
        counters = devices.isEmpty ? nil : DiskCounters(devices: devices.map { ($0.name, $0.bsd) })
        // The old trace stops with its own map (what it still has to deliver was read on the old devices); the new
        // map goes to its replacement.
        let restart = !first && trace != nil
        if restart { stopTrace() }
        tellTrace(devices)
        if restart { startTrace() }
    }

    /// Which devices and mount points belong to which volume, for the program list. A volume mounted somewhere
    /// else counts where it is.
    private func tellTrace(_ devices: [(name: String, bsd: String, mountedAt: String?)]) {
        mountKey = devices.map { "\($0.name)=\($0.mountedAt ?? "")" }.joined(separator: ",")
        var traced = ProgramTrace.Devices()
        traced.whole = counters?.wholeDisk
        traced.container = counters?.container
        for device in devices {
            traced.volumes[device.bsd] = device.name
            if let path = device.mountedAt { traced.mounts.append((path, device.name)) }
        }
        traceDevices = traced
        trace?.setDevices(traced)
    }

    /// Compare the SSD's devices with what the counters and the trace were built for. True if they were rebuilt.
    private func updateDevices(now: TimeInterval) -> Bool {
        let (devices, attachments) = controller.ssdDevices()
        let key = "\(attachments):" + devices.map { "\($0.name)=\($0.bsd)" }.joined(separator: ",")
        if key != deviceKey {
            rebuildCounters(devices, key: key, now: now)
            return true
        }
        if devices.map({ "\($0.name)=\($0.mountedAt ?? "")" }).joined(separator: ",") != mountKey {
            self.devices = devices   // the newest mount points, also for a later counter retry
            tellTrace(devices)
        }
        return false
    }

    private func tick() {
        let now = StatsWindow.uptime
        _ = updateDevices(now: now)
        trace?.checkDropped()
        // The rule may have been removed or changed elsewhere (Settings, or by hand): one stat call. Gone: stop and
        // offer the setup. Changed: start over, so sudo decides again.
        if trace != nil {
            if !SudoRule.isInstalled { sudoRuleChanged() }
            else if SudoRule.signature() != ruleSignature { startTrace() }
        } else if traceState == .needsSetup, SudoRule.signature() != ruleSignature {
            ruleSignature = SudoRule.signature()
            if SudoRule.isInstalled { startTrace() }   // added elsewhere: try it
        }
        defer { render(now: now) }
        if countersIncomplete, !devices.isEmpty {
            countersIncomplete = false
            counters = DiskCounters(devices: devices.map { ($0.name, $0.bsd) })
            baseline = nil
            tellTrace(devices)   // the whole disk and container may only be known now
        }
        guard let counters else {
            lastDisk = nil
            return
        }
        let reading = counters.read()
        lastDisk = reading.disk
        guard let base = baseline, now - base.time <= StatsWindow.longestInterval else {
            // The first reading, or the first after a sleep: a starting point, no bar. Nothing from before the
            // sleep counts as current, and the program list starts over too.
            if baseline != nil {
                liveSince = now
                programsSince = now
            }
            baseline = (now, reading)
            return
        }
        let elapsed = now - base.time
        guard elapsed >= 0.5 else { return }
        baseline = (now, reading)
        let shared = rowNames.count - 1
        var read = [Double](repeating: 0, count: rowNames.count)
        var write = [Double](repeating: 0, count: rowNames.count)
        var volumesRead: UInt64 = 0
        var volumesWritten: UInt64 = 0
        var complete = true   // every attached volume's counters were there both times
        for row in 0..<shared {
            let name = rowNames[row]
            guard let new = reading.volumes[name], let old = base.reading.volumes[name] else {
                if attached.contains(name) { complete = false }
                continue
            }
            guard complete else { continue }
            let r = StatsWindow.delta(new.read, old.read)
            let w = StatsWindow.delta(new.written, old.written)
            volumesRead += r
            volumesWritten += w
            read[row] = Double(r) / elapsed
            write[row] = Double(w) / elapsed
        }
        // A counter that wasn't there (an attached volume's, or the whole disk's) leaves the totals unknown: a gap,
        // not a partial sum, and the registry entries are looked up again for the next reading.
        guard complete, reading.disk != nil, base.reading.disk != nil else {
            countersIncomplete = true
            liveSince = now   // nothing from before shows as current (the program list carries on: fs_usage ran)
            return
        }
        // The rows add up to the whole disk: shared gets what the volumes don't account for. The volumes' and the
        // disk's counters are read one after the other, so in a busy second the volumes can run ahead of the
        // disk; then they are scaled down to it (the next second's disk reading catches up, as shared).
        if let new = reading.disk, let old = base.reading.disk {
            for (disk, volumes, rates) in [(StatsWindow.delta(new.read, old.read), volumesRead, 0),
                                           (StatsWindow.delta(new.written, old.written), volumesWritten, 1)] {
                if disk >= volumes {
                    let rest = Double(disk - volumes) / elapsed
                    if rates == 0 { read[shared] = rest } else { write[shared] = rest }
                } else if volumes > 0 {
                    let factor = Double(disk) / Double(volumes)
                    for row in 0..<shared {
                        if rates == 0 { read[row] *= factor } else { write[row] *= factor }
                    }
                }
            }
        }
        let sample = Sample(time: now, seconds: elapsed, wall: Date(), read: read, write: write)
        samples.append(sample)
        // The highest so far, per row and for the whole SSD (every row, whatever is checked).
        for row in rowNames.indices {
            rowMax[row].read = max(rowMax[row].read, read[row])
            rowMax[row].write = max(rowMax[row].write, write[row])
        }
        let everything = Array(repeating: true, count: rowNames.count)
        let total = (read: sample.total(everything, read: true), write: sample.total(everything, read: false))
        if total.read > totalMax.read { totalMax.read = total.read; totalMax.readAt = sample.wall }
        if total.write > totalMax.write { totalMax.write = total.write; totalMax.writeAt = sample.wall }
        let oldest = now - StatsWindow.span - 2
        if let keep = samples.firstIndex(where: { $0.time >= oldest }), keep > 0 { samples.removeFirst(keep) }
    }

    /// A counter that went backwards was reset (the disk was attached again): no traffic counted for it.
    private static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    // MARK: - programs

    private func startTrace() {
        stopTrace()
        guard !closed else { return }
        guard SudoRule.isInstalled else {
            traceState = .needsSetup
            renderPrograms(now: StatsWindow.uptime)
            return
        }
        traceState = .starting
        // The setup is adding the rule and will check it with a trace of its own: wait for it (AppController
        // calls sudoRuleChanged() when it is done).
        guard !controller.sudoRuleVerifying else { return renderPrograms(now: StatsWindow.uptime) }
        let trace = ProgramTrace()
        ruleSignature = SudoRule.signature()
        trace.setDevices(traceDevices)
        trace.onBatch = { [weak self] batch, current in self?.add(batch, current: current) }
        trace.onDropped = { [weak self] in self?.noteHistoryGap("fs_usage dropped events while the Mac was busy") }
        trace.onCoverage = { [weak self] at in self?.coverage(from: at) }
        trace.onState = { [weak self] state in
            guard let self else { return }
            self.traceState = state
            if state == .running {
                self.controller.sudoRuleTried(works: true)
                self.coverage(from: trace.firstCoverage ?? StatsWindow.uptime)   // a quiet run's launch at worst
            }
            if self.historySince != nil, state == .needsSetup || { if case .failed = state { return true }; return false }() {
                self.noteHistoryGap("the program list stopped for a while")
            }
            self.historyDirty = true
            if state == .needsSetup, SudoRule.isInstalled {
                self.controller.sudoRuleTried(works: false, refusal: trace.refusal)
            }
            self.renderPrograms(now: StatsWindow.uptime)
        }
        self.trace = trace
        trace.start()   // waits for any earlier trace to exit first
        renderPrograms(now: StatsWindow.uptime)
    }

    private func stopTrace() {
        if let trace {
            // The history has a hole from here until a new trace runs: say so, with any drops it reported.
            trace.checkDropped()
            if let dropped = trace.droppedAt, dropped > (openedAtClock ?? 0) {
                noteHistoryGap("fs_usage dropped events while the Mac was busy")
            }
            if !closed {
                if historySince != nil { noteHistoryGap("the program list stopped for a while") }
                else if trace.launchedAt != nil { stoppedBeforeHistory = true }   // reported once data turns up
            }
        }
        trace?.stop()
        trace = nil
        buckets = []
    }

    private func add(_ batch: ProgramTrace.Batch, current: Bool) {
        guard !closed else { return }
        let shared = rowNames.count - 1
        // Data counts from when it came in, even if the "running" news of its trace never arrived (stopped first).
        coverage(from: batch.at)
        // The history takes every batch (its volumes were told apart when it was parsed); the live rates only
        // those parsed under the current device map.
        for (key, bytes) in batch.bytes {
            let row = key.volume.flatMap { rowNames.firstIndex(of: $0) } ?? shared
            var since = history[key.program, default: [:]][row] ?? (0, 0)
            since.read = since.read.addingSaturated(bytes.read)
            since.written = since.written.addingSaturated(bytes.written)
            history[key.program, default: [:]][row] = since
            if checked[row] {   // unchecked rows are kept, but don't change what is shown
                rankTotals[key.program, default: 0] = rankTotals[key.program, default: 0]
                    .addingSaturated(bytes.read).addingSaturated(bytes.written)
                rankChanged.insert(key.program)
                historyDirty = true
            }
        }
        guard current else { return }
        var index = buckets.lastIndex { $0.second == batch.second }
        if index == nil {
            buckets.append((batch.second, [:]))
            buckets.sort { $0.second < $1.second }
            index = buckets.lastIndex { $0.second == batch.second }
        }
        guard let index else { return }
        for (key, bytes) in batch.bytes {
            let row = key.volume.flatMap { rowNames.firstIndex(of: $0) } ?? shared
            let programKey = ProgramKey(row: row, program: key.program)
            var sum = buckets[index].bytes[programKey] ?? (0, 0)
            sum.read = sum.read.addingSaturated(bytes.read)
            sum.written = sum.written.addingSaturated(bytes.written)
            buckets[index].bytes[programKey] = sum
        }
        let newest = buckets.last?.second ?? batch.second
        buckets.removeAll { $0.second < newest - StatsWindow.programSeconds - 1 }
    }

    /// The busiest programs on the checked rows over the last whole seconds, as bytes per second.
    private func topPrograms(now: TimeInterval) -> [(name: String, read: Double, write: Double)] {
        let current = Int(now)
        // Seconds since the last device change or gap count from the next whole second (the second it
        // happened in may hold traffic from before it).
        let first = max(current - StatsWindow.programSeconds, Int(programsSince.rounded(.up)))
        var sums: [String: (read: UInt64, written: UInt64)] = [:]
        for bucket in buckets where bucket.second >= first && bucket.second < current {
            for (key, bytes) in bucket.bytes where checked[key.row] {
                var sum = sums[key.program] ?? (0, 0)
                sum.read = sum.read.addingSaturated(bytes.read)
                sum.written = sum.written.addingSaturated(bytes.written)
                sums[key.program] = sum
            }
        }
        // Divide by the time fs_usage actually ran within those seconds: it may have started (or the SSD come
        // back) less than three seconds ago, and each 30 s run ends with a short gap before the next.
        let seconds = trace?.watched(from: Double(first), to: Double(current)) ?? 0
        guard seconds >= 0.25 else { return [] }
        var rows: [(name: String, read: Double, write: Double)] = []
        for (name, sum) in sums where sum.read + sum.written > 0 {
            rows.append((name, Double(sum.read) / seconds, Double(sum.written) / seconds))
        }
        rows.sort { $0.read + $0.write > $1.read + $1.write }
        return rows
    }

    // MARK: - showing

    private func render(now: TimeInterval) {
        let last = samples.last.flatMap { $0.time > liveSince ? $0 : nil }   // nothing from before a replug
        let connected = counters != nil
        readValue.stringValue = !connected ? "–" : last.map { formatRate($0.total(checked, read: true)) } ?? "…"
        writeValue.stringValue = !connected ? "–" : last.map { formatRate($0.total(checked, read: false)) } ?? "…"
        // While connected the graph moves on with the clock, so a missing reading shows as a gap; while the SSD
        // is away it stays where it was.
        if connected || graphRight == nil {
            graphRight = now
            graphRightWall = connected ? Date() : nil   // opened while the SSD was away: when it left is unknown
        }
        if connected {
            frozen = false
        } else if !frozen {
            frozen = true
            frozenAt = graphRightWall   // the last moment it was seen, the graph's edge
        }
        axisLeft.stringValue = frozen ? "10 minutes before that" : "10 minutes ago"
        axisRight.stringValue = !frozen ? "now"
            : frozenAt.map { "unplugged at \($0.formatted(date: .omitted, time: .shortened))" } ?? "SSD disconnected"
        graph.update(samples: samples, checked: checked, right: graphRight ?? now,
                     loading: connected && samples.isEmpty,
                     message: connected ? nil : "SSD not connected. The graph continues when it is back.")
        let shared = rowNames.count - 1
        volumeText = rowNames.indices.map { row in
            let present = row == shared ? !attached.isEmpty : attached.contains(rowNames[row])
            var now = [present && connected ? "…" : "–", present && connected ? "…" : "–"]
            if present, connected, let last { now = [formatRate(last.read[row]), formatRate(last.write[row])] }
            return now + [rowMax[row].read > 0 ? formatRate(rowMax[row].read) : "–",
                          rowMax[row].write > 0 ? formatRate(rowMax[row].write) : "–"]
        }
        volumeTable.update(count: rowNames.count)
        func high(_ value: Double, _ at: Date?) -> String {
            guard let at, value > 0 else { return "–" }
            return "\(formatRate(value)) at \(at.formatted(date: .omitted, time: .standard))"
        }
        maxReadLabel.stringValue = "Highest read since opened: " + high(totalMax.read, totalMax.readAt)
        maxWriteLabel.stringValue = "Highest write since opened: " + high(totalMax.write, totalMax.writeAt)
        totalsLabel.stringValue = totalsText()
        renderPrograms(now: now)
        renderHistory()
    }

    private func renderPrograms(now: TimeInterval) {
        var rows: [(name: String, read: Double, write: Double)] = []
        var note: String?
        var spinning = false
        var incomplete = false
        setupButton.isHidden = true
        retryButton.isHidden = true
        switch traceState {
        case nil, .needsSetup?:
            note = SudoRule.isInstalled
                ? "sudo didn't run fs_usage through the rule, although it is there\(trace?.refusal.map { " (sudo said: \($0))" } ?? ""). Set it up again, or check that /etc/sudoers includes /etc/sudoers.d."
                : "The program list needs a one-time setup: a sudo rule that lets SSD Monitor run fs_usage."
            setupButton.isHidden = false
        case .starting?:
            note = controller.sudoRuleVerifying ? "Waiting for the setup to check the rule…" : "Starting fs_usage…"
            spinning = true
        case .failed(let why)?:
            note = "The program list stopped: \(why)"
            retryButton.isHidden = false
        case .running?:
            rows = topPrograms(now: now)
            if rows.isEmpty { note = "No program is reading or writing the checked volumes right now." }
            if let dropped = trace?.droppedAt, now - dropped < 10 { incomplete = true }
        }
        liveRows = rows   // every program; the list scrolls
        liveTable.update(count: rows.count)
        liveTable.note.stringValue = note ?? ""
        liveTable.note.toolTip = note   // all of it, if a long sudo message is cut short
        liveTable.overlay.isHidden = !rows.isEmpty || note == nil
        liveWarning.isHidden = !incomplete
        programSpinner.isHidden = !spinning
        spinning ? programSpinner.startAnimation(nil) : programSpinner.stopAnimation(nil)
    }

    /// macOS keeps only the first 16 characters (bytes) of a program's name: a name that long may have been cut.
    private static func programName(_ name: String) -> (text: String, tooltip: String) {
        guard name.utf8.count >= 16 else { return (name, name) }
        return (name + "…", name + "\nmacOS keeps only the first 16 characters of a program's name, so programs whose names start alike are counted together.")
    }

    private func volumeCell(_ row: Int, _ column: Int) -> StatTable.Cell {
        guard rowNames.indices.contains(row) else { return .init() }
        guard column > 0 else {
            let tooltip = row == rowNames.count - 1
                ? "Reads and writes APFS makes for the SSD as a whole (checkpoints, space maps): they belong to no single volume."
                : rowNames[row]
            return .init(text: rowNames[row], tooltip: tooltip, on: checked[row])
        }
        let text = volumeText.indices.contains(row) ? volumeText[row][column - 1] : "–"
        return .init(text: text, secondary: !checked[row] || text == "–" || text == "…")   // unchecked: dimmed
    }

    private func liveCell(_ row: Int, _ column: Int) -> StatTable.Cell {
        guard liveRows.indices.contains(row) else { return .init() }
        let program = liveRows[row]
        switch column {
        case 0:
            let name = StatsWindow.programName(program.name)
            return .init(text: name.text, tooltip: name.tooltip)
        case 1: return .init(text: program.read > 0 ? formatRate(program.read) : "–", secondary: program.read == 0)
        default: return .init(text: program.write > 0 ? formatRate(program.write) : "–", secondary: program.write == 0)
        }
    }

    private func historyCell(_ row: Int, _ column: Int) -> StatTable.Cell {
        guard historyLines.indices.contains(row) else {   // the last row: what didn't fit
            guard row == historyLines.count, historyHidden > 0, column == 0 else { return .init() }
            return .init(text: "\(historyHidden) more program\(historyHidden == 1 ? "" : "s"), not shown", secondary: true,
                         tooltip: "They read and wrote less than the programs above. The list shows at most \(StatsWindow.historyLines) lines.")
        }
        let line = historyLines[row]
        switch column {
        case 0:
            guard line.total else { return .init() }
            let name = StatsWindow.programName(line.name)
            return .init(text: name.text, bold: true, tooltip: name.tooltip)
        case 1:
            return .init(text: line.volume, secondary: true, tooltip: line.volume.isEmpty ? nil : line.volume)
        case 2:
            return .init(text: line.read > 0 ? formatBytes(line.read) : "–", bold: line.total && line.read > 0,
                         secondary: !line.total || line.read == 0)
        case 3:
            return .init(text: line.written > 0 ? formatBytes(line.written) : "–", bold: line.total && line.written > 0,
                         secondary: !line.total || line.written == 0)
        default:
            return .init(bar: (Double(line.read) / historyScale, Double(line.written) / historyScale, !line.total))
        }
    }

    /// "Since plugged in at 9:12: 1.20 TB read, 380 GB written": the whole disk's own counters, which start when
    /// the SSD is attached. When it was attached is known if the app saw it happen (AppController).
    private func totalsText() -> String {
        guard let disk = lastDisk else { return counters == nil ? "SSD not connected" : "" }
        let amounts = "\(formatBytes(disk.read)) read, \(formatBytes(disk.written)) written"
        guard let attachment = controller.currentAttachment(), let id = attachment.id, id == counters?.diskEntryID else {
            return "Since plugged in: \(amounts)"   // the app hasn't looked at this attachment yet
        }
        guard let at = attachment.at else {
            return "Since plugged in (before SSD Monitor started, \(StatsWindow.when(controller.startedAt))): \(amounts)"
        }
        return "Since plugged in at \(StatsWindow.when(at)): \(amounts)"
    }

    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Every program since the window opened, busiest first: its totals on the checked rows, then one line per
    /// row (volume) it used.
    /// Tracing ran from `clock` time `at`: the history counts from the earliest such moment (compared on the
    /// monotonic clock; the wall time is kept for showing).
    private func coverage(from at: TimeInterval) {
        guard !closed, historySince.map({ at < $0.clock }) ?? true else { return }
        if historySince == nil, stoppedBeforeHistory { noteHistoryGap("the program list stopped for a while") }
        historySince = (at, Date(timeIntervalSinceNow: at - StatsWindow.uptime))
    }

    private func noteHistoryGap(_ why: String) {
        guard !historyGaps.contains(why) else { return }
        historyGaps.append(why)
        historyDirty = true
    }

    private func renderHistory() {
        if let dropped = trace?.droppedAt, dropped > (openedAtClock ?? 0) { noteHistoryGap("fs_usage dropped events while the Mac was busy") }
        historyTitle.stringValue = historySince.map { since in
            since.clock - (openedAtClock ?? since.clock) > 1
                ? "Programs since \(since.wall.formatted(date: .omitted, time: .standard)) (when the program list started)"
                : "Programs since the window opened"
        } ?? "Programs since the window opened"
        let gaps = historyGaps.isEmpty ? "" : "Some reads and writes may be missing: " + historyGaps.joined(separator: "; ") + "."
        StatsWindow.set(historyGapNote, gaps)
        historyGapNote.toolTip = gaps.isEmpty ? nil : gaps
        historyGapNote.isHidden = historyGaps.isEmpty
        StatsWindow.set(historyTable.note, historySince == nil ? "Shows once the program list runs."
            : "No program has read or written the checked volumes since then.")
        guard historyDirty else { return }   // nothing new: no sorting, no redrawing
        historyDirty = false
        var lines: [HistoryLine] = []
        updateRanking()
        // Per-volume lines are made only for the programs shown.
        var programs: [(name: String, read: UInt64, written: UInt64)] = []
        for program in rankOrder {
            var read: UInt64 = 0
            var written: UInt64 = 0
            for (row, bytes) in history[program] ?? [:] where checked[row] {
                read = read.addingSaturated(bytes.read)
                written = written.addingSaturated(bytes.written)
            }
            programs.append((program, read, written))
            if programs.count > StatsWindow.historyLines { break }   // enough to fill the lines
        }
        // At most this many lines, so a window left open while thousands of differently named programs touch the
        // SSD stays light: the busiest programs, in order, until one doesn't fit; the rest are counted.
        var shown = 0
        for program in programs {
            let rows = (history[program.name] ?? [:])
                .filter { checked[$0.key] && $0.value.read.addingSaturated($0.value.written) > 0 }
                .sorted { $0.value.read.addingSaturated($0.value.written) > $1.value.read.addingSaturated($1.value.written) }
            // While programs remain after this one, a line is kept for "N more programs", so the list never has more
            // than historyLines (and one that fits exactly shows every program).
            let reserved = rankTotals.count > shown + 1 ? 1 : 0
            guard lines.count + 1 + rows.count <= StatsWindow.historyLines - reserved else { break }
            let band = shown % 2 == 1
            shown += 1
            lines.append(HistoryLine(name: program.name, volume: "", read: program.read, written: program.written,
                                     total: true, band: band))
            for (row, bytes) in rows {
                lines.append(HistoryLine(name: program.name, volume: rowNames[row], read: bytes.read,
                                         written: bytes.written, total: false, band: band))
            }
        }
        historyHidden = rankTotals.count - shown   // every program with traffic on the checked rows, minus those shown
        historyScale = max(1, programs.first.map { Double($0.read.addingSaturated($0.written)) } ?? 1)   // the busiest
        historyLines = lines
        historyTable.update(count: lines.count + (historyHidden > 0 ? 1 : 0))
        historyTable.overlay.isHidden = !lines.isEmpty
    }

    /// Only a changed text is set (so an unchanged row costs nothing).
    private static func set(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    /// Busiest first. Only the programs whose totals changed move (a binary search for their new place); a
    /// checkbox change ranks everything again.
    private func updateRanking() {
        if rankRebuild {
            rankRebuild = false
            rankChanged = []
            rankTotals = [:]
            for (program, byRow) in history {
                var total: UInt64 = 0
                for (row, bytes) in byRow where checked[row] { total = total.addingSaturated(bytes.read).addingSaturated(bytes.written) }
                if total > 0 { rankTotals[program] = total }
            }
            rankOrder = Array(rankTotals.keys.sorted { (rankTotals[$0] ?? 0, $1) > (rankTotals[$1] ?? 0, $0) }
                .prefix(StatsWindow.rankedPrograms))
            return
        }
        guard !rankChanged.isEmpty else { return }
        // Only the top programs are kept in order (all that 300 lines can show); totals only grow, so a program
        // outside can only come in, pushing the last one out.
        rankOrder.removeAll { rankChanged.contains($0) }
        for program in rankChanged {
            let total = rankTotals[program] ?? 0
            guard total > 0 else { continue }
            var low = 0
            var high = rankOrder.count
            while low < high {
                let mid = (low + high) / 2
                if (rankTotals[rankOrder[mid]] ?? 0, program) > (total, rankOrder[mid]) { low = mid + 1 } else { high = mid }
            }
            if low < StatsWindow.rankedPrograms { rankOrder.insert(program, at: low) }
        }
        if rankOrder.count > StatsWindow.rankedPrograms { rankOrder.removeLast(rankOrder.count - StatsWindow.rankedPrograms) }
        rankChanged = []
    }

    // MARK: - actions

    private func setChecked(_ row: Int, _ on: Bool) {
        guard checked.indices.contains(row), checked[row] != on else { return }
        checked[row] = on
        historyDirty = true
        rankRebuild = true
        render(now: StatsWindow.uptime)
    }

    @objc private func setUpRule() { controller.showSudoSetup(welcome: false) }

    @objc private func retryTrace() { startTrace() }

    // MARK: - building

    private func build() -> NSWindow {
        let window = UI.window(title: "SSD Statistics", size: NSSize(width: 1000, height: 860), resizable: true, delegate: self)

        func headline(_ title: String, _ color: NSColor, _ value: NSTextField) -> NSStackView {
            value.alignment = .left
            let dot = UI.symbol("circle.fill", color: color, size: 9)
            let name = UI.label(title, color: .secondaryLabelColor)
            return UI.stack([value, UI.stack([dot, name], vertical: false, spacing: 5)], vertical: true, spacing: 2)
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            return view
        }
        /// A title (and anything at its right), then the box under it, both the section's full width.
        func section(_ titleRow: [NSView], _ box: NSView) -> NSStackView {
            let row = UI.stack(titleRow, vertical: false, spacing: 12, alignment: .firstBaseline)
            row.distribution = .fill
            let stack = UI.stack([row, box], vertical: true, spacing: 8)
            stack.distribution = .fill
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return stack
        }

        let highs = UI.stack([maxReadLabel, maxWriteLabel], vertical: true, spacing: 4, alignment: .trailing)
        let header = UI.stack([headline("Read", GraphView.readColor, readValue),
                               headline("Write", GraphView.writeColor, writeValue), spacer(), highs],
                              vertical: false, spacing: 48)
        header.distribution = .fill   // the spacer takes the extra width: the highs sit at the right edge
        let axis = UI.stack([axisLeft, spacer(), axisRight], vertical: false)

        // Volumes, and beside them the programs of the last seconds: both as tall as the volumes (more scroll).
        let volumes = section([UI.label("Volumes", weight: .semibold)], volumeTable.box)
        liveWarning.toolTip = "The Mac was too busy for fs_usage to see every disk access just now: the list may be incomplete."
        liveWarning.isHidden = true
        liveWarning.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        for view in [programSpinner, setupButton, retryButton] as [NSView] { liveTable.accessories.addArrangedSubview(view) }
        let live = section([UI.label("Programs, last \(StatsWindow.programSeconds) seconds", weight: .semibold),
                            spacer(), liveWarning], liveTable.box)
        let lists = UI.stack([volumes, live], vertical: false, spacing: 20, alignment: .top)
        lists.distribution = .fill
        // At least 6 rows, so a short volume list still leaves room for the live list's note and Set Up… button.
        let listHeight = volumeTable.height(rows: min(max(rowNames.count, 6), StatsWindow.shownVolumes))

        // Every program since the window opened: the full width, and all the height left over (it scrolls).
        historyTitle.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        historyGapNote.setContentCompressionResistancePriority(.init(200), for: .horizontal)   // cut short first
        let history = section([historyTitle, spacer(), historyGapNote], historyTable.box)

        let column = UI.stack([header, totalsLabel, graph, axis, lists, history], vertical: true, spacing: 10)
        column.distribution = .fill
        column.setCustomSpacing(6, after: header)
        column.setCustomSpacing(4, after: graph)
        column.setCustomSpacing(18, after: axis)
        column.setCustomSpacing(20, after: lists)
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        totalsLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let content = NSView()
        content.addSubview(column)
        let inset: CGFloat = 40
        // Nothing here grows with what is listed: the window keeps the size it is given.
        // The graph's 190 points give way to the window's size (below windowSizeStayPut, 500), down to 130.
        let graphHeight = graph.heightAnchor.constraint(equalToConstant: 190)
        graphHeight.priority = .init(490)
        let liveShare = live.widthAnchor.constraint(equalTo: volumes.widthAnchor, multiplier: 0.7)
        liveShare.priority = .init(650)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),   // highs at the right
            totalsLabel.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            graph.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            axis.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            lists.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            history.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            graphHeight,
            graph.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            volumeTable.box.heightAnchor.constraint(equalToConstant: listHeight),
            liveTable.box.heightAnchor.constraint(equalToConstant: listHeight),
            volumes.widthAnchor.constraint(greaterThanOrEqualToConstant: 470),
            live.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            liveShare,
            historyTable.box.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        window.contentView = content
        // The smallest window that shows all of it; the history takes any height above that.
        // (measured with the graph at its smallest, 130 points)
        graphHeight.isActive = false
        let smallest = content.fittingSize
        graphHeight.isActive = true
        window.contentMinSize = NSSize(width: max(860, smallest.width), height: smallest.height)
        // A frame saved by the earlier layout (which grew with the history) is dropped.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame SSD Statistics")
        window.setFrameAutosaveName("SSD Statistics window")
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {   // never taller or wider than the screen
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }
        render(now: StatsWindow.uptime)
        return window
    }
}

/// The 10-minute graph: reads (pink) up from the middle line, writes (blue) down, one bar per reading (about a
/// second; a late reading's bar covers its whole interval), each half scaled to its own highest bar in view.
/// Hovering shows the time and speeds of the bar under the pointer.
@MainActor
final class GraphView: NSView {
    static let readColor = NSColor.systemPink
    static let writeColor = NSColor.systemBlue
    /// The scale never goes below this, so an idle trickle doesn't fill the graph.
    static let minimumScale = 100_000.0

    private var samples: [StatsWindow.Sample] = []
    private var checked: [Bool] = []
    private var right: TimeInterval = 0
    private var hover: CGFloat?
    private let spinner = NSProgressIndicator()
    private let message = UI.label(color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(samples: [StatsWindow.Sample], checked: [Bool], right: TimeInterval, loading: Bool, message: String?) {
        self.samples = samples
        self.checked = checked
        self.right = right
        loading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        self.message.stringValue = message ?? ""
        self.message.isHidden = message == nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    private var plot: NSRect { bounds.insetBy(dx: 8, dy: 20) }

    private func x(_ time: TimeInterval) -> CGFloat {
        plot.minX + CGFloat((time - (right - StatsWindow.span)) / StatsWindow.span) * plot.width
    }

    private func time(at x: CGFloat) -> TimeInterval {
        right - StatsWindow.span + TimeInterval((x - plot.minX) / plot.width) * StatsWindow.span
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        frame.fill()
        NSColor.separatorColor.setStroke()
        frame.stroke()

        let plot = self.plot
        let left = right - StatsWindow.span
        let bars = samples.filter { $0.time > left }.map { sample in
            (from: x(sample.time - sample.seconds), to: x(sample.time),
             read: sample.total(checked, read: true), write: sample.total(checked, read: false))
        }
        let readScale = max(GraphView.minimumScale, bars.map(\.read).max() ?? 0)
        let writeScale = max(GraphView.minimumScale, bars.map(\.write).max() ?? 0)
        let half = plot.height / 2

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        GraphView.readColor.setFill()
        for bar in bars where bar.read > 0 {
            let width = max(1, bar.to - bar.from)
            NSBezierPath(rect: NSRect(x: bar.to - width, y: plot.midY, width: width,
                                      height: max(0.5, CGFloat(bar.read / readScale) * half))).fill()
        }
        GraphView.writeColor.setFill()
        for bar in bars where bar.write > 0 {
            let width = max(1, bar.to - bar.from)
            let height = max(0.5, CGFloat(bar.write / writeScale) * half)
            NSBezierPath(rect: NSRect(x: bar.to - width, y: plot.midY - height, width: width, height: height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: plot.minX, y: plot.midY - 0.25, width: plot.width, height: 0.5)).fill()

        if !bars.isEmpty {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            NSAttributedString(string: "↑ " + formatRate(readScale), attributes: attributes)
                .draw(at: NSPoint(x: plot.minX, y: bounds.maxY - 16))
            NSAttributedString(string: "↓ " + formatRate(writeScale), attributes: attributes)
                .draw(at: NSPoint(x: plot.minX, y: bounds.minY + 4))
        }

        if let hover, plot.minX...plot.maxX ~= hover { drawHover(at: hover) }
    }

    /// A line at the pointer and a label for the reading whose interval covers that moment.
    private func drawHover(at pointer: CGFloat) {
        let plot = self.plot
        NSColor.labelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(rect: NSRect(x: pointer - 0.5, y: plot.minY, width: 1, height: plot.height)).fill()

        let moment = time(at: pointer)
        let sample = samples.first { moment > $0.time - $0.seconds && moment <= $0.time }
        let text = NSMutableAttributedString()
        let body = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if let sample {
            var when = sample.wall.formatted(date: .omitted, time: .standard)
            if sample.seconds > 1.5 {
                when = sample.wall.addingTimeInterval(-sample.seconds).formatted(date: .omitted, time: .standard)
                    + " – " + when + " (average)"
            }
            text.append(NSAttributedString(string: when + "\n",
                                           attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor.labelColor]))
            let lines = [("Read", sample.total(checked, read: true), GraphView.readColor),
                         ("Write", sample.total(checked, read: false), GraphView.writeColor)]
            for (index, line) in lines.enumerated() {
                text.append(NSAttributedString(string: "● ", attributes: [.font: body, .foregroundColor: line.2]))
                text.append(NSAttributedString(string: "\(line.0)  \(formatRate(line.1))\(index == 0 ? "\n" : "")",
                                               attributes: [.font: body, .foregroundColor: NSColor.labelColor]))
            }
        } else {
            text.append(NSAttributedString(string: "No reading for this moment",
                                           attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let size = text.boundingRect(with: NSSize(width: 360, height: 200), options: [.usesLineFragmentOrigin]).size
        var box = NSRect(x: pointer + 10, y: plot.maxY - size.height - 12, width: size.width + 14, height: size.height + 10)
        if box.maxX > bounds.maxX - 4 { box.origin.x = pointer - 10 - box.width }
        let bubble = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        bubble.fill()
        NSColor.separatorColor.setStroke()
        bubble.stroke()
        text.draw(with: NSRect(x: box.minX + 7, y: box.minY + 5, width: size.width, height: size.height),
                  options: [.usesLineFragmentOrigin])
    }
}
