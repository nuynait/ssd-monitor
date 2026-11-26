import AppKit

/// The menu bar icon and its menu. The menu is built only when opened (the sound list only when its submenu
/// opens) and emptied again a moment after it closes; the icon image is made only when its state changes.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let sounds = NSMenu()
    private unowned let controller: AppController
    private var shownIcon = ""
    private var open = false

    init(controller: AppController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        sounds.delegate = self
        sounds.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "SSD Monitor"
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { open = true }
    }

    /// Free the items once the menu is closed. A second later, not right away: the chosen item's action is
    /// performed after the menu closes.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.open else { return }
                self.emptyMenu()
                self.sounds.removeAllItems()
            }
        }
    }

    /// The sound submenu is one object, reused: detach it from its item first (a menu can belong to only one
    /// item at a time), then drop the items.
    private func emptyMenu() {
        for item in menu.items where item.submenu === sounds { item.submenu = nil }
        menu.removeAllItems()
    }

    func refresh() {
        let (symbol, color): (String, NSColor?)
        switch controller.iconState {
        case .healthy: (symbol, color) = ("externaldrive.fill", nil)
        case .issue: (symbol, color) = ("externaldrive.fill.badge.xmark", .systemRed)
        case .waiting: (symbol, color) = ("externaldrive.badge.minus", nil)
        case .busy: (symbol, color) = ("externaldrive.fill.badge.timemachine", nil)
        case .error: (symbol, color) = ("externaldrive.badge.questionmark", .systemGray)
        }
        let key = symbol + (color?.description ?? "")
        guard key != shownIcon else { return }
        shownIcon = key
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "SSD Monitor")
            ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "SSD Monitor")
        if let color, let tinted = base?.withSymbolConfiguration(.init(paletteColors: [color])) {
            tinted.isTemplate = false
            item.button?.image = tinted
        } else {
            base?.isTemplate = true
            item.button?.image = base
        }
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sounds { fillSounds(); return }
        controller.refreshForMenu()   // fresh volume states and free space, read only now
        emptyMenu()
        let h = controller.health

        // 1. Free space first.
        if let error = controller.configError {
            menu.addItem(line("Can't watch the SSD: \(error)", mark: "●", color: .systemGray))
        } else if !h.connected {
            menu.addItem(line("SSD not connected", mark: "●", color: .systemRed))
        } else if let free = controller.freeBytes {
            let color: NSColor = free < AppController.lowSpaceRed ? .systemRed
                : free < AppController.lowSpaceYellow ? .systemYellow : .systemGreen
            menu.addItem(line("SSD free space: \(formatGB(free))", mark: "●", color: color, bold: true))
        } else {
            menu.addItem(line("SSD free space: unknown (no volume mounted)", mark: "●", color: .systemGray))
        }
        menu.addItem(.separator())

        // 2. Each volume.
        for s in h.volumes {
            let text: String
            let mark: String
            let color: NSColor
            switch s.state {
            case .ok: (mark, color, text) = ("✓", .systemGreen, "\(s.volume.name)  \(Paths.tilde(s.volume.path))")
            case .readOnly: (mark, color, text) = ("!", .systemOrange, "\(s.volume.name)  read-only")
            case .elsewhere(let path): (mark, color, text) = ("!", .systemOrange, "\(s.volume.name)  mounted at \(Paths.tilde(path))")
            case .notMounted: (mark, color, text) = ("✗", .systemRed, "\(s.volume.name)  not mounted")
            case .absent: (mark, color, text) = ("✗", .systemRed, "\(s.volume.name)  not attached")
            }
            menu.addItem(line(text, mark: mark, color: color))
        }
        menu.addItem(.separator())

        // 3. Actions.
        if controller.canShowAlarm { menu.addItem(action("Show the alert…", #selector(showAlert))) }
        menu.addItem(action("Run resume now", #selector(runResume), enabled: controller.canResume))
        menu.addItem(action("Safely eject the SSD…", #selector(eject), enabled: controller.canEject))
        menu.addItem(.separator())
        menu.addItem(action("Open Statistics…", #selector(openStatistics), enabled: controller.canOpenStatistics))
        menu.addItem(.separator())

        menu.addItem(requireItem())

        let soundItem = NSMenuItem(title: "Alert sound", action: nil, keyEquivalent: "")
        soundItem.submenu = sounds   // filled when it opens
        menu.addItem(soundItem)
        menu.addItem(action("Test the alarm sound", #selector(testSound), enabled: Preferences.alertSound != nil))

        let login = action(Preferences.launchAtLoginNeedsApproval
                           ? "Launch at login (approve in System Settings › Login Items)" : "Launch at login",
                           #selector(toggleLogin))
        login.state = Preferences.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(.separator())
        let settings = action("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(action("Quit SSD Monitor", #selector(quit)))
    }

    /// "Require the SSD", with its state in the title and the choices in a small submenu (made with the menu,
    /// freed with it).
    private func requireItem() -> NSMenuItem {
        let until = Preferences.requireSnoozedUntil.flatMap { $0 > Date() ? $0 : nil }
        let title: String
        switch until {
        case nil: title = "Require the SSD"
        case .distantFuture?: title = "Require the SSD: off"
        case let date?:
            let day = Calendar.current.isDateInToday(date) ? Date.FormatStyle.DateStyle.omitted : .abbreviated
            title = "Require the SSD: snoozed until \(date.formatted(date: day, time: .shortened))"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.state = until == nil ? .on : .off
        let sub = NSMenu()
        sub.autoenablesItems = false
        let on = action("On", #selector(requireOn))
        on.state = until == nil ? .on : .off
        sub.addItem(on)
        sub.addItem(.separator())
        for choice in AppController.snoozeChoices {
            let entry = action(choice.long, #selector(requireSnooze(_:)))
            entry.representedObject = choice.seconds.map { NSNumber(value: $0) }
            if choice.seconds == nil { entry.state = until == .distantFuture ? .on : .off }
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    /// The alert sounds: None, then every macOS alert sound (system and the user's own).
    private func fillSounds() {
        sounds.removeAllItems()
        let current = Preferences.alertSound
        let none = action("None", #selector(pickSound(_:)))
        none.representedObject = ""
        none.state = current == nil ? .on : .off
        sounds.addItem(none)
        sounds.addItem(.separator())
        for name in Preferences.availableSounds() {
            let entry = action(name, #selector(pickSound(_:)))
            entry.representedObject = name
            entry.state = name == current ? .on : .off
            sounds.addItem(entry)
        }
    }

    private func line(_ text: String, mark: String, color: NSColor, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let title = NSMutableAttributedString(string: mark + "  ", attributes: [.foregroundColor: color])
        title.append(NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.menuFont(ofSize: 0).withWeight(.semibold) : NSFont.menuFont(ofSize: 0),
        ]))
        item.attributedTitle = title
        item.isEnabled = true
        return item
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func showAlert() { controller.showAlarmFromMenu() }
    @objc private func runResume() { controller.runResumeNow() }
    @objc private func eject() { controller.confirmEject() }
    @objc private func testSound() { controller.testSound() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func openStatistics() { controller.openStatistics() }
    @objc private func openSettings() { controller.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func requireOn() { controller.turnRequireOn() }

    @objc private func requireSnooze(_ sender: NSMenuItem) {
        controller.snoozeFromMenu(for: (sender.representedObject as? NSNumber)?.doubleValue)
    }

    @objc private func pickSound(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? ""
        Preferences.alertSound = name.isEmpty ? nil : name
        if !name.isEmpty { controller.previewSound(name) }
    }

    @objc private func toggleLogin() {
        Preferences.setLaunchAtLogin(!Preferences.launchAtLogin)
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
