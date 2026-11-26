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
    static let programRows = 8                // rows made up front; more are added when needed
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
    private var volumeCells: [(check: NSButton, read: NSTextField, write: NSTextField)] = []
    private var programCells: [(name: NSTextField, read: NSTextField, write: NSTextField)] = []
    private var programGrid: NSGridView?
    private let programNote = UI.label(color: .secondaryLabelColor, wraps: true)
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
        super.init()
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
        self.devices = devices
        countersIncomplete = false
        attached = Set(devices.map(\.name))
        baseline = nil
        liveSince = now
        programsSince = now
        counters = devices.isEmpty ? nil : DiskCounters(devices: devices.map { ($0.name, $0.bsd) })
        tellTrace(devices)
        if !first, trace != nil { startTrace() }
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
        guard let counters else { return }
        let reading = counters.read()
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
        samples.append(Sample(time: now, seconds: elapsed, wall: Date(), read: read, write: write))
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
        trace.onBatch = { [weak self] batch in self?.add(batch) }
        trace.onState = { [weak self] state in
            guard let self else { return }
            self.traceState = state
            if state == .running { self.controller.sudoRuleTried(works: true) }
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
        trace?.stop()
        trace = nil
        buckets = []
    }

    private func add(_ batch: ProgramTrace.Batch) {
        let shared = rowNames.count - 1
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
        for (row, cells) in volumeCells.enumerated() {
            let present = row == shared ? !attached.isEmpty : attached.contains(rowNames[row])
            if present, connected, let last {
                cells.read.stringValue = formatRate(last.read[row])
                cells.write.stringValue = formatRate(last.write[row])
            } else {
                cells.read.stringValue = present && connected ? "…" : "–"
                cells.write.stringValue = present && connected ? "…" : "–"
            }
        }
        renderPrograms(now: now)
    }

    private func renderPrograms(now: TimeInterval) {
        guard let programGrid else { return }
        var rows: [(name: String, read: Double, write: Double)] = []
        var note: String?
        var spinning = false
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
            if let dropped = trace?.droppedAt, now - dropped < 10 {
                note = (note.map { $0 + " " } ?? "")
                    + "The Mac was too busy for fs_usage to see every disk access just now: the list may be incomplete."
            }
        }
        while programCells.count < rows.count { addProgramRow(to: programGrid) }   // every program; the lists scroll
        for (i, cells) in programCells.enumerated() {
            let used = i < rows.count
            programGrid.row(at: i + 1).isHidden = !used
            guard used else { continue }
            // macOS keeps only the first 16 characters of a program's name: a name that long may have been cut,
            // and programs whose names start alike are counted together.
            let cut = rows[i].name.utf8.count >= 16   // 16 bytes, not characters
            cells.name.stringValue = rows[i].name + (cut ? "…" : "")
            cells.name.toolTip = cut ? "macOS keeps only the first 16 characters of a program's name, so programs whose names start alike are counted together." : nil
            cells.read.stringValue = rows[i].read > 0 ? formatRate(rows[i].read) : "–"
            cells.write.stringValue = rows[i].write > 0 ? formatRate(rows[i].write) : "–"
        }
        programGrid.isHidden = rows.isEmpty
        programNote.stringValue = note ?? ""
        programNote.isHidden = note == nil
        programSpinner.isHidden = !spinning
        spinning ? programSpinner.startAnimation(nil) : programSpinner.stopAnimation(nil)
    }

    // MARK: - actions

    @objc private func toggleRow(_ sender: NSButton) {
        guard checked.indices.contains(sender.tag) else { return }
        checked[sender.tag] = sender.state == .on
        render(now: StatsWindow.uptime)
    }

    @objc private func setUpRule() { controller.showSudoSetup(welcome: false) }

    @objc private func retryTrace() { startTrace() }

    // MARK: - building

    private func build() -> NSWindow {
        let window = UI.window(title: "SSD Statistics", size: NSSize(width: 800, height: 660), resizable: true, delegate: self)
        window.contentMinSize = NSSize(width: 720, height: 520)

        func headline(_ title: String, _ color: NSColor, _ value: NSTextField) -> NSStackView {
            value.alignment = .left
            let dot = UI.symbol("circle.fill", color: color, size: 9)
            let name = UI.label(title, color: .secondaryLabelColor)
            return UI.stack([value, UI.stack([dot, name], vertical: false, spacing: 5)], vertical: true, spacing: 2)
        }
        let header = UI.stack([headline("Read", GraphView.readColor, readValue),
                               headline("Write", GraphView.writeColor, writeValue)], vertical: false, spacing: 48)


        let axisSpacer = NSView()
        axisSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let axis = UI.stack([axisLeft, axisSpacer, axisRight], vertical: false)

        // Volumes, with a checkbox each.
        let small = NSFont.smallSystemFontSize
        var volumeRows: [[NSView]] = [[UI.label("Volume", size: small, color: .secondaryLabelColor),
                                       UI.label("Read", size: small, color: .secondaryLabelColor),
                                       UI.label("Write", size: small, color: .secondaryLabelColor)]]
        for (row, name) in rowNames.enumerated() {
            let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(toggleRow(_:)))
            check.tag = row
            check.state = .on
            if row == rowNames.count - 1 {
                check.toolTip = "Reads and writes APFS makes for the SSD as a whole (checkpoints, space maps): they belong to no single volume."
            }
            let read = UI.number()
            let write = UI.number()
            volumeCells.append((check, read, write))
            volumeRows.append([check, read, write])
        }
        let volumeGrid = NSGridView(views: volumeRows)
        configure(volumeGrid)

        // Programs.
        let programRows: [[NSView]] = [[UI.label("Program", size: small, color: .secondaryLabelColor),
                                        UI.label("Read", size: small, color: .secondaryLabelColor),
                                        UI.label("Write", size: small, color: .secondaryLabelColor)]]
        let programGrid = NSGridView(views: programRows)
        configure(programGrid)
        for _ in 0..<StatsWindow.programRows { addProgramRow(to: programGrid) }
        self.programGrid = programGrid
        let programButtons = UI.stack([programSpinner, setupButton, retryButton], vertical: false)

        let volumesTitle = UI.label("Volumes", weight: .semibold)
        let programsTitle = UI.label("Programs, last \(StatsWindow.programSeconds) seconds", weight: .semibold)
        let volumesColumn = UI.stack([volumesTitle, volumeGrid], vertical: true, spacing: 8)
        // The columns are as tall as the taller one: the room left over goes below everything.
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        let programsColumn = UI.stack([programsTitle, programGrid, programNote, programButtons, filler],
                                      vertical: true, spacing: 8)
        programsColumn.distribution = .fill
        let bottom = UI.stack([volumesColumn, programsColumn], vertical: false, spacing: 32, alignment: .top)
        bottom.distribution = .fillEqually

        // The lists scroll when the window is too short for them (a Mac with many volumes); the graph keeps at
        // least 150 points and takes any height left over.
        let document = FlippedView()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bottom)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        let column = UI.stack([header, graph, axis, scroll], vertical: true, spacing: 10)
        column.distribution = .fill
        column.setCustomSpacing(4, after: graph)
        column.setCustomSpacing(20, after: axis)
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        graph.setContentHuggingPriority(.init(1), for: .vertical)
        let content = NSView()
        content.addSubview(column)
        let inset: CGFloat = 40
        let fullLists = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fullLists.priority = .init(700)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            graph.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            axis.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            graph.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            fullLists,
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: document.topAnchor),
            bottom.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            programNote.widthAnchor.constraint(equalTo: programsColumn.widthAnchor),
        ])
        window.contentView = content
        window.setFrameAutosaveName("SSD Statistics")
        render(now: StatsWindow.uptime)
        return window
    }

    private func addProgramRow(to grid: NSGridView) {
        let name = UI.label()
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let read = UI.number()
        let write = UI.number()
        programCells.append((name, read, write))
        grid.addRow(with: [name, read, write])
    }

    private func configure(_ grid: NSGridView) {
        grid.rowSpacing = 5
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        for i in 1...2 {
            grid.column(at: i).xPlacement = .trailing
            grid.column(at: i).width = 84
        }
    }
}

/// A scroll view's content that starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
