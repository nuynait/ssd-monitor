import AppKit

struct OverlayButton {
    enum Style { case normal, primary, destructive }
    let title: String
    let style: Style
    let action: () -> Void

    init(_ title: String, _ style: Style = .normal, _ action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }
}

/// What the overlay shows. `progress`: nil = no bar, a negative value = spinning bar, 0...1 = filled bar.
struct OverlayContent {
    enum Tone { case alarm, progress, success, failure, info }
    var tone: Tone
    var title: String
    var message: String = ""
    var details: [String] = []
    var progress: Double? = nil
    var progressLabel: String = ""
    var buttons: [OverlayButton] = []
    /// A second, smaller row of buttons under its own label ("Require the SSD"'s snooze choices).
    var snoozeLabel: String = ""
    var snoozeButtons: [OverlayButton] = []
    /// Set for screens that a click anywhere dismisses (success, info).
    var onClick: (() -> Void)? = nil
}

/// A full-screen layer on the main display, above every window and full-screen app, with a card in the
/// middle. The window exists only while something is shown; `close()` frees it.
@MainActor
final class Overlay {
    private var window: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var progressText: NSTextField?
    private var targets: [ButtonTarget] = []
    private var onClick: (() -> Void)?
    private var screenObserver: NSObjectProtocol?
    private var hiddenForPassword = false
    private var shownTitle = ""

    var isShown: Bool { window != nil }

    func show(_ content: OverlayContent) {
        if content.title != shownTitle {   // one line per screen (progress updates don't count)
            Log.write("screen: \(content.title)")
            shownTitle = content.title
        }
        let window = self.window ?? makeWindow()
        self.window = window
        onClick = content.onClick
        window.contentView = makeContent(content, frame: window.frame)
        if !window.isVisible, !hiddenForPassword { window.orderFrontRegardless() }
    }

    /// Update only the bar and its label (no rebuild) while a step runs.
    func updateProgress(_ value: Double, label: String) {
        if let bar = progressBar, !bar.isIndeterminate { bar.doubleValue = max(0, min(1, value)) }
        progressText?.stringValue = label
    }

    /// Get out of the way of a macOS password dialog; `unhide()` brings it back. Updates in between
    /// don't bring it forward.
    func hide() {
        hiddenForPassword = true
        window?.orderOut(nil)
    }

    func unhide() {
        hiddenForPassword = false
        window?.orderFrontRegardless()
    }

    func close() {
        if window != nil { Log.write("screen closed: \(shownTitle)") }
        shownTitle = ""
        hiddenForPassword = false
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        progressBar = nil
        progressText = nil
        targets = []
        onClick = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    // MARK: - window

    private static func mainScreenFrame() -> NSRect {
        (NSScreen.screens.first ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func makeWindow() -> NSPanel {
        let panel = OverlayPanel(contentRect: Overlay.mainScreenFrame(),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.setFrame(Overlay.mainScreenFrame(), display: true) }
        }
        return panel
    }

    // MARK: - content

    private func makeContent(_ content: OverlayContent, frame: NSRect) -> NSView {
        targets = []
        progressBar = nil
        progressText = nil

        let backdrop = Backdrop(frame: NSRect(origin: .zero, size: frame.size))
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        backdrop.onClick = { [weak self] in self?.onClick?() }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 26, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let (symbol, colors) = Overlay.icon(for: content.tone)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .semibold).applying(.init(paletteColors: colors))) {
            stack.addArrangedSubview(NSImageView(image: image))
        }

        // The card's height is bounded whatever the content: one line for the title, at most 8 for the
        // message, and the details in a scrolling area at most 260 points high (all of them, selectable).
        // The buttons always stay on screen.
        let title = Overlay.singleLine(content.title, font: .boldSystemFont(ofSize: 22), truncate: .byTruncatingTail)
        title.alignment = .center
        stack.addArrangedSubview(title)

        if !content.message.isEmpty {
            let message = Overlay.wrapping(content.message, font: .systemFont(ofSize: 14), align: .center)
            message.maximumNumberOfLines = 8
            message.cell?.truncatesLastVisibleLine = true
            stack.addArrangedSubview(message)
        }

        if !content.details.isEmpty {
            stack.addArrangedSubview(Overlay.detailsView(content.details))
        }

        if let progress = content.progress {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            bar.isIndeterminate = progress < 0
            if progress < 0 { bar.startAnimation(nil) } else { bar.doubleValue = min(1, progress) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 460).isActive = true
            stack.addArrangedSubview(bar)
            progressBar = bar
            let label = NSTextField(labelWithString: content.progressLabel)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            progressText = label
        }

        if !content.buttons.isEmpty {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            for spec in content.buttons { row.addArrangedSubview(makeButton(spec, size: .large)) }
            stack.setCustomSpacing(22, after: stack.arrangedSubviews.last ?? stack)
            stack.addArrangedSubview(row)
        }

        if !content.snoozeButtons.isEmpty {
            let label = NSTextField(labelWithString: content.snoozeLabel)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            stack.setCustomSpacing(22, after: stack.arrangedSubviews.last ?? stack)
            stack.addArrangedSubview(label)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            for spec in content.snoozeButtons { row.addArrangedSubview(makeButton(spec, size: .regular)) }
            stack.setCustomSpacing(8, after: label)
            stack.addArrangedSubview(row)
        }

        card.addSubview(stack)
        backdrop.addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.widthAnchor.constraint(equalToConstant: 580),
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])
        return backdrop
    }

    /// The main choice and a destructive one are drawn in their own color: the overlay is never the active
    /// window, and AppKit draws a tinted bezel gray in a window that isn't.
    private func makeButton(_ spec: OverlayButton, size: NSControl.ControlSize) -> NSButton {
        let target = ButtonTarget(spec.action)
        targets.append(target)
        let button: NSButton
        switch spec.style {
        case .primary:
            button = FilledButton(title: spec.title, fill: .controlAccentColor, target: target,
                                  action: #selector(ButtonTarget.fire))
            button.keyEquivalent = "\r"
        case .destructive:
            button = FilledButton(title: spec.title, fill: .systemRed, target: target,
                                  action: #selector(ButtonTarget.fire))
            button.hasDestructiveAction = true
        case .normal:
            button = FirstClickButton(title: spec.title, target: target, action: #selector(ButtonTarget.fire))
            button.bezelStyle = .push
            button.controlSize = size
        }
        return button
    }

    private static func wrapping(_ text: String, font: NSFont, align: NSTextAlignment) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.alignment = align
        field.isSelectable = false
        field.preferredMaxLayoutWidth = 516
        return field
    }

    /// All detail lines, wrapped to the card's width (a long path breaks onto the next line), in a scrolling area
    /// no taller than 260 points.
    private static func detailsView(_ lines: [String]) -> NSView {
        let width: CGFloat = 516
        // The text view's own text system, with its container fixed to exactly the area's width (it does not
        // follow the view), so lines wrap there; the view is then sized to the laid-out text.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.string = lines.joined(separator: "\n")
        var height: CGFloat = 16
        if let manager = text.layoutManager, let container = text.textContainer {
            manager.ensureLayout(for: container)
            height = ceil(manager.usedRect(for: container).height)
        }
        text.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let scroll = NSScrollView()
        scroll.scrollerStyle = .overlay   // a scroller never takes width from the text
        scroll.documentView = text
        scroll.hasVerticalScroller = height > 260
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(height, 260)).isActive = true
        return scroll
    }

    /// One line, never wider than the card: longer text is cut with "…".
    private static func singleLine(_ text: String, font: NSFont, truncate: NSLineBreakMode) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = truncate
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 516).isActive = true
        return field
    }

    /// Symbol and palette: the first color is the inner mark (the "!", the check, the X), the second the shape.
    /// Two colors, so the mark stays visible (one color would paint it the same as its shape).
    private static func icon(for tone: OverlayContent.Tone) -> (String, [NSColor]) {
        switch tone {
        case .alarm: return ("externaldrive.fill.badge.exclamationmark", [.white, .systemRed])
        case .progress: return ("externaldrive.fill", [.controlAccentColor])
        case .success: return ("checkmark.circle.fill", [.white, .systemGreen])
        case .failure: return ("xmark.octagon.fill", [.white, .systemRed])
        case .info: return ("externaldrive.fill", [.systemBlue])
        }
    }
}

/// Borderless panels can't become key by default; buttons with a key equivalent need it.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The dark full-screen layer. Swallows clicks (nothing underneath gets them) and reports them when allowed.
private final class Backdrop: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reacts on the first click even though the app is not active.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A button filled with its own color and a white title, the same whether or not its window is active.
/// Darker while pressed. Reacts on the first click too.
private final class FilledButton: NSButton {
    private let fill: NSColor

    init(title: String, fill: NSColor, target: AnyObject, action: Selector) {
        self.fill = fill
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .medium)
        self.font = font
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: font])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 28, height: max(size.height + 10, 30))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = isHighlighted ? (fill.blended(withFraction: 0.25, of: .black) ?? fill) : fill
        layer?.backgroundColor = color.cgColor
    }
}

private final class ButtonTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
