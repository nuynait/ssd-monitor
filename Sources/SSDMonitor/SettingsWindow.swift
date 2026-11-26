import AppKit

/// Settings. One row for now: the sudo rule behind the Statistics window's program list, with its state and
/// Set Up… (the setup window) or Remove… (macOS's password dialog). The menu keeps the other settings.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private unowned let controller: AppController
    private var window: NSWindow?
    private var task: AdminTask?
    private var error: String?
    var onClose: (() -> Void)?

    private let stateIcon = NSImageView()
    private let stateText = UI.label()
    private let spinner = UI.spinner()
    private lazy var button = UI.button("", self, #selector(buttonPressed))
    private lazy var repairButton = UI.button("Set Up Again…", self, #selector(setUpAgain))
    private let errorText = UI.label(size: NSFont.smallSystemFontSize, color: .systemOrange, wraps: true)

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    func show() {
        let window = self.window ?? build()
        self.window = window
        refresh()
        UI.show(window)
    }

    /// The rule was added or removed (here, in the setup window, or by hand).
    func refresh() {
        guard window != nil else { return }
        let installed = SudoRule.isInstalled
        let broken = installed && controller.sudoRuleWorks == false   // there, but sudo still asks
        let busy = task != nil
        let (symbol, color, text): (String, NSColor, String) =
            broken ? ("exclamationmark.triangle.fill", .systemOrange, "Not working")
            : installed ? ("checkmark.circle.fill", .systemGreen, "Set up")
            : ("minus.circle", .secondaryLabelColor, "Not set up")
        stateIcon.image = UI.symbol(symbol, color: color, size: 15).image
        stateText.stringValue = busy ? "Waiting for your password…" : text
        stateIcon.isHidden = busy
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        button.title = installed ? "Remove…" : "Set Up…"
        button.isEnabled = !busy && !controller.sudoRuleChanging
        repairButton.isHidden = !broken
        repairButton.isEnabled = !busy && !controller.sudoRuleChanging
        var notes: [String] = []
        if broken {
            let said = controller.sudoRuleRefusal.map { " sudo said: \($0)." } ?? ""
            notes.append("sudo didn't run fs_usage through the rule, although it is there.\(said) Set it up again, or check that /etc/sudoers includes /etc/sudoers.d.")
        }
        if let error { notes.append("Removing the rule didn't work: \(error)") }
        errorText.stringValue = notes.joined(separator: "\n")
        errorText.isHidden = notes.isEmpty
        if let window { UI.fit(window) }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        window?.contentView = nil
        window = nil
        onClose?()
        onClose = nil
    }

    private func build() -> NSWindow {
        let window = UI.window(title: "SSD Monitor Settings", size: NSSize(width: 480, height: 150),
                               resizable: false, delegate: self)
        let title = UI.label("Program list in Statistics", weight: .semibold)
        let detail = UI.label("""
            A sudo rule lets SSD Monitor run \(SudoRule.command.joined(separator: " ")) without a password, only \
            while the Statistics window is open, to see which programs read and write the SSD.
            """, size: NSFont.smallSystemFontSize, color: .secondaryLabelColor, wraps: true)
        let state = UI.stack([stateIcon, spinner, stateText], vertical: false, spacing: 6)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UI.stack([title, spacer, state, repairButton, button], vertical: false, spacing: 12)
        let column = UI.stack([row, detail, errorText], vertical: true, spacing: 8)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 480),
            row.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -20),
        ])
        detail.preferredMaxLayoutWidth = 440
        errorText.preferredMaxLayoutWidth = 440
        window.contentView = content
        return window
    }

    @objc private func buttonPressed() {
        error = nil
        guard SudoRule.isInstalled else {
            refresh()
            controller.showSudoSetup(welcome: false)
            return
        }
        task = controller.removeSudoRule { [weak self] outcome in
            guard let self else { return }
            self.task = nil
            if case .failed(let why) = outcome { self.error = why }
            self.refresh()
        }
        if task == nil { error = "another change to the rule is still going (the setup)." }
        refresh()
    }

    @objc private func setUpAgain() {
        error = nil
        controller.showSudoSetup(welcome: false)
    }
}
