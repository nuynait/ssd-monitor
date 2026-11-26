import AppKit

/// A list in the Statistics window: a plain macOS table in a rounded box like the graph's, with fixed row heights
/// and its own scrolling, so the window never grows with what it lists. It is refreshed in place each second:
/// the rows it already shows get their new values (no reload, so a checkbox being clicked keeps its view and the
/// scroll position stays), and only a change in the number of rows adds or removes any.
@MainActor
final class StatTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Column {
        enum Kind { case text, number, check, bar }
        var title: String
        var width: CGFloat
        var kind: Kind = .text
        var tooltip: String?
    }

    /// What one cell shows.
    struct Cell {
        var text = ""
        var bold = false
        var secondary = false
        var tooltip: String?
        var on = false                                            // a check column's box
        var bar: (read: Double, write: Double, faint: Bool)?      // a bar column: parts of the full width, 0...1
    }

    static let rowHeight: CGFloat = 22

    let box: NSView = RoundedBox()        // what goes into the window
    let table = NSTableView()
    /// Shown over the rows when there is nothing to list: a note, and a row for a spinner or buttons.
    let overlay = NSStackView()
    let note = UI.label(color: .secondaryLabelColor, wraps: true)
    let accessories = NSStackView()
    var content: (_ row: Int, _ column: Int) -> Cell = { _, _ in Cell() }
    /// Rows drawn on a shaded band (a group of rows that belong together).
    var shaded: ((_ row: Int) -> Bool)?
    var onCheck: ((_ row: Int, _ on: Bool) -> Void)?
    private let columns: [Column]
    private let flexible: Int
    private(set) var count = 0

    /// `flexible` is the column that takes the width left over (the first or the last).
    init(columns: [Column], flexible: Int, alternating: Bool = true) {
        self.columns = columns
        self.flexible = flexible
        super.init()
        table.style = .fullWidth
        table.rowHeight = StatTable.rowHeight
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.usesAlternatingRowBackgroundColors = alternating
        table.backgroundColor = .controlBackgroundColor
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none   // a list to read: nothing to select
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false      // the columns always fit: no column can be pushed out of view
        table.allowsColumnSelection = false
        table.focusRingType = .none
        // The flexible column is sized here (fitColumns), every time the box changes size, including the first
        // time: AppKit's own column autoresizing only follows a later resize, so a window opened at its narrowest
        // would cut the last columns off.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = min(column.width, 60)
            tableColumn.headerToolTip = column.tooltip
            if column.kind == .number { tableColumn.headerCell.alignment = .right }
            tableColumn.resizingMask = []
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self

        let scroll = FittingScrollView()
        scroll.onTile = { [weak self] in self?.fitColumns() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)

        note.alignment = .center
        note.maximumNumberOfLines = 4             // a long message is cut short (all of it in the tooltip), so the
        note.cell?.truncatesLastVisibleLine = true   // button under it stays inside the box
        accessories.orientation = .horizontal
        accessories.spacing = 8
        overlay.orientation = .vertical
        overlay.alignment = .centerX
        overlay.spacing = 10
        overlay.addArrangedSubview(note)
        overlay.addArrangedSubview(accessories)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        box.addSubview(overlay)
        let header = table.headerView?.frame.height ?? 0
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: header / 2),   // below the header
            note.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -48),
        ])
    }

    /// The flexible column takes exactly the width the others leave in the box (never less than its minimum).
    private func fitColumns() {
        guard let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0,
              table.tableColumns.indices.contains(flexible), table.numberOfColumns > 0 else { return }
        let column = table.tableColumns[flexible]
        let used = table.rect(ofColumn: table.numberOfColumns - 1).maxX   // all the columns, with their spacing
        let width = max(column.minWidth, column.width + clip.bounds.width - used)
        if abs(width - column.width) >= 0.5 { column.width = width }
    }

    /// The box's height for this many rows and the header.
    func height(rows: Int) -> CGFloat {
        (table.headerView?.frame.height ?? 0) + CGFloat(rows) * (StatTable.rowHeight + table.intercellSpacing.height) + 2
    }

    /// Show `count` rows, asking `content` for each shown cell again.
    func update(count: Int) {
        if count != self.count {
            self.count = count
            NSAnimationContext.runAnimationGroup { context in   // rows come and go at once, without fading
                context.duration = 0
                context.allowsImplicitAnimation = false
                table.noteNumberOfRowsChanged()   // rows that come into view ask `content` themselves
            }
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard row < self.count else { return }
            if let band = rowView as? BandRow { band.shaded = self.shaded?(row) ?? false }
            for column in self.columns.indices {
                if let view = rowView.view(atColumn: column) as? NSView { self.apply(view, row: row, column: column) }
            }
        }
    }

    // MARK: - the table's questions

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else {
            return nil
        }
        let view = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) ?? makeCell(index)
        apply(view, row: row, column: index)
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard let shaded else { return nil }
        let view = BandRow()
        view.shaded = shaded(row)
        return view
    }

    // MARK: - cells

    private func makeCell(_ index: Int) -> NSView {
        let column = columns[index]
        let view: NSView
        switch column.kind {
        case .check:
            let cell = CheckCell()
            cell.button.target = self
            cell.button.action = #selector(checked(_:))
            view = cell
        case .bar:
            view = BarCell()
        case .text, .number:
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.alignment = column.kind == .number ? .right : .left
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            view = cell
        }
        view.identifier = NSUserInterfaceItemIdentifier("\(index)")
        return view
    }

    private static let fonts: [Bool: [Bool: NSFont]] = [   // [number][bold]
        false: [false: .systemFont(ofSize: NSFont.systemFontSize),
                true: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)],
        true: [false: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
               true: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)],
    ]

    /// Only what changed is set, so an unchanged row costs next to nothing.
    private func apply(_ view: NSView, row: Int, column: Int) {
        let cell = content(row, column)
        switch columns[column].kind {
        case .check:
            guard let button = (view as? CheckCell)?.button else { return }
            if button.title != cell.text { button.title = cell.text }
            let state: NSControl.StateValue = cell.on ? .on : .off
            if button.state != state { button.state = state }
            button.tag = row
            if button.toolTip != cell.tooltip { button.toolTip = cell.tooltip }
        case .bar:
            (view as? BarCell)?.set(cell.bar)
        case .text, .number:
            guard let field = (view as? NSTableCellView)?.textField else { return }
            if field.stringValue != cell.text { field.stringValue = cell.text }
            let font = StatTable.fonts[columns[column].kind == .number]?[cell.bold]
            if let font, field.font != font { field.font = font }
            let color: NSColor = cell.secondary ? .secondaryLabelColor : .labelColor
            if field.textColor != color { field.textColor = color }
            if field.toolTip != cell.tooltip { field.toolTip = cell.tooltip }
        }
    }

    @objc private func checked(_ sender: NSButton) { onCheck?(sender.tag, sender.state == .on) }
}

/// A scroll view that says when it has laid itself out again (a new size, a scroller shown or hidden).
private final class FittingScrollView: NSScrollView {
    var onTile: (() -> Void)?

    override func tile() {
        super.tile()
        onTile?()
    }
}

/// The rounded, outlined box a table sits in (the same look as the graph's).
private final class RoundedBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {   // AppKit sets the current appearance here, so light and dark both fit
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

/// A row that can sit on a shaded band.
private final class BandRow: NSTableRowView {
    var shaded = false {
        didSet { if shaded != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard shaded else { return }
        NSColor.alternatingContentBackgroundColors[1].setFill()
        dirtyRect.fill()
    }
}

/// A checkbox with the row's name.
private final class CheckCell: NSTableCellView {
    let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.cell?.lineBreakMode = .byTruncatingTail   // a long name is cut short (full name in the tooltip)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A bar of reads (pink) then writes (blue), each part as long as its share of the cell's width.
private final class BarCell: NSView {
    private var value: (read: Double, write: Double, faint: Bool)?

    func set(_ value: (read: Double, write: Double, faint: Bool)?) {
        let old = self.value
        guard old?.read != value?.read || old?.write != value?.write || old?.faint != value?.faint else { return }
        self.value = value
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let value else { return }
        let height: CGFloat = value.faint ? 4 : 7
        let alpha: CGFloat = value.faint ? 0.5 : 1
        // Each part that isn't zero gets at least 1 point (a tiny write next to a huge read still shows); if that
        // makes them longer than the cell, the longer part gives way. The second starts where the first ends.
        let parts = [(value.read, GraphView.readColor), (value.write, GraphView.writeColor)]
        var widths = parts.map { $0.0 > 0 ? max(1, CGFloat(min(1, $0.0)) * bounds.width) : 0 }
        let over = widths.reduce(0, +) - bounds.width
        if over > 0 {
            let longer = widths[0] >= widths[1] ? 0 : 1
            widths[longer] = max(1, widths[longer] - over)
        }
        var x = bounds.minX
        let y = bounds.midY - height / 2
        for (index, part) in parts.enumerated() where widths[index] > 0 {
            part.1.withAlphaComponent(alpha).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: widths[index], height: height)).fill()
            x += widths[index]
        }
    }
}
