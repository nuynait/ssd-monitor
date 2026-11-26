import AppKit

/// Small helpers shared by the app's ordinary windows (Statistics, Settings, the sudo rule setup).
@MainActor
enum UI {
    static func window(title: String, size: NSSize, resizable: Bool, delegate: NSWindowDelegate) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()
        return window
    }

    /// Bring a window forward. The app has no Dock icon, so it has to activate itself first.
    static func show(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Size the window to its content (the content view's constraints decide), keeping its top edge in place.
    static func fit(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    static func label(_ text: String = "", size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        if !wraps { field.lineBreakMode = .byTruncatingTail }
        return field
    }

    /// Right-aligned numbers whose digits don't jump as they change.
    static func number(size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        field.alignment = .right
        return field
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        if primary { button.keyEquivalent = "\r" }
        return button
    }

    static func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImageView {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        return NSImageView(image: image ?? NSImage())
    }

    static func spinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        return spinner
    }

    static func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat = 8,
                      alignment: NSLayoutConstraint.Attribute? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = spacing
        stack.alignment = alignment ?? (vertical ? .leading : .centerY)
        return stack
    }

    /// The app has no menu bar of its own (it lives in the status bar), but a main menu still gives its windows
    /// ⌘, (Settings), ⌘W, ⌘C and ⌘A.
    static func installMainMenu(settings: (target: AnyObject, action: Selector)) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: settings.action, keyEquivalent: ",")
        settingsItem.target = settings.target
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

/// Speeds as Finder and Activity Monitor count bytes (1 MB = 1,000,000 bytes).
func formatRate(_ bytesPerSecond: Double) -> String {
    let v = max(0, bytesPerSecond)
    switch v {
    case ..<1_000: return String(format: "%.0f B/s", v)
    case ..<1_000_000: return String(format: "%.0f KB/s", v / 1_000)
    case ..<100_000_000: return String(format: "%.1f MB/s", v / 1_000_000)
    case ..<1_000_000_000: return String(format: "%.0f MB/s", v / 1_000_000)
    default: return String(format: "%.2f GB/s", v / 1_000_000_000)
    }
}

/// Amounts as Finder counts bytes (1 GB = 1,000,000,000 bytes).
func formatBytes(_ bytes: UInt64) -> String {
    let v = Double(bytes)
    switch v {
    case ..<1_000: return "\(bytes) B"
    case ..<1_000_000: return String(format: "%.0f KB", v / 1_000)
    case ..<1_000_000_000: return String(format: "%.0f MB", v / 1_000_000)
    case ..<1_000_000_000_000: return String(format: "%.1f GB", v / 1_000_000_000)
    default: return String(format: "%.2f TB", v / 1_000_000_000_000)
    }
}
