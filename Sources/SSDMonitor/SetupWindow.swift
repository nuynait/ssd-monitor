import AppKit

/// Sets up the sudo rule for the Statistics window's program list: what it is and why, then Set up → macOS's
/// password dialog → a check that sudo accepts the rule → a green check and Finish. As the welcome screen
/// (the first launch without the rule) it offers "Not now"; opened from Settings or Statistics, "Cancel".
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private enum Stage: Equatable { case intro, working(String), done, failed(String) }

    private let welcome: Bool
    private unowned let controller: AppController
    private var window: NSWindow?
    private var stage = Stage.intro
    private var task: AdminTask?
    private var check: ProgramTrace?
    private var checkTimeout: DispatchWorkItem?
    /// Called once the window has closed, whatever closed it.
    var onClose: (() -> Void)?

    // Views that change with the stage.
    private let statusIcon = NSImageView()
    private let statusSpinner = UI.spinner()
    private let statusText = UI.label(wraps: true)
    private lazy var statusRow = UI.stack([statusIcon, statusSpinner, statusText], vertical: false)
    private lazy var buttons = UI.stack([], vertical: false)

    init(controller: AppController, welcome: Bool) {
        self.controller = controller
        self.welcome = welcome
        super.init()
    }

    func show() {
        // A finished setup whose rule has gone since (removed in Settings or by hand) starts over.
        let reset = stage == .done && !SudoRule.isInstalled
        if reset { stage = .intro }
        let window = self.window ?? build()
        self.window = window
        if reset { render() }
        UI.fit(window)
        UI.show(window)
    }

    /// The rule changed elsewhere (Settings removed it, say): a finished setup's green check no longer holds.
    func ruleChanged() {
        guard stage == .done else { return }
        stage = .intro
        render()
    }

    /// For quitting, or the window closing: stop what runs, without waiting for anything.
    func stop() {
        task?.cancel()
        task = nil
        endCheck()
        releaseStatistics()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        window?.contentView = nil
        window = nil
        onClose?()
        onClose = nil
    }

    // MARK: - building

    private func build() -> NSWindow {
        let window = UI.window(title: welcome ? "Welcome to SSD Monitor" : "Set Up the Program List",
                               size: NSSize(width: 500, height: 330), resizable: false, delegate: self)
        let icon = UI.symbol("externaldrive.fill.badge.checkmark", color: .controlAccentColor, size: 34)
        let title = UI.label(welcome ? "Welcome to SSD Monitor" : "Set up the program list", size: 17, weight: .semibold)
        let body = UI.label("""
            The Statistics window (in the menu bar menu) shows how fast the SSD reads and writes. It can also \
            list the programs doing it, using Apple's fs_usage tool, which needs administrator rights.

            Set up adds one sudo rule, so SSD Monitor can start exactly this command without asking for your \
            password each time:
            """, wraps: true)
        let command = NSTextField(labelWithString: SudoRule.command.joined(separator: " "))
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.isSelectable = true
        let note = UI.label("""
            The rule is the file \(SudoRule.file.replacingOccurrences(of: "/private/etc/", with: "/etc/")). \
            fs_usage runs only while Statistics is open, 30 seconds at a time. You can remove the rule in Settings.
            """, size: NSFont.smallSystemFontSize, color: .secondaryLabelColor, wraps: true)
        let head = UI.stack([icon, title], vertical: false, spacing: 10)
        statusText.isSelectable = true
        let column = UI.stack([head, body, command, note, statusRow, buttons], vertical: true, spacing: 12)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        column.setCustomSpacing(18, after: note)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),   // the window fits its content
            content.widthAnchor.constraint(equalToConstant: 500),
            buttons.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -24),
        ])
        for field in [body, note, statusText] {
            field.preferredMaxLayoutWidth = 452
        }
        window.contentView = content
        render()
        return window
    }

    private func render() {
        statusSpinner.stopAnimation(nil)
        statusSpinner.isHidden = true
        statusIcon.isHidden = true
        statusRow.isHidden = false
        buttons.setViews([], in: .trailing)
        switch stage {
        case .intro:
            statusRow.isHidden = true
            buttons.setViews([UI.button(welcome ? "Not now" : "Cancel", self, #selector(closeWindow)),
                              UI.button("Set Up…", self, #selector(setUp), primary: true)], in: .trailing)
        case .working(let text):
            statusSpinner.isHidden = false
            statusSpinner.startAnimation(nil)
            statusText.stringValue = text
            statusText.textColor = .labelColor
            let wait = UI.button(welcome ? "Not now" : "Cancel", self, #selector(closeWindow))
            buttons.setViews([wait], in: .trailing)
        case .done:
            statusIcon.image = UI.symbol("checkmark.circle.fill", color: .systemGreen, size: 22).image
            statusIcon.isHidden = false
            statusText.stringValue = "Done. Statistics can now list the programs that use the SSD."
            statusText.textColor = .labelColor
            buttons.setViews([UI.button("Finish", self, #selector(closeWindow), primary: true)], in: .trailing)
        case .failed(let why):
            statusIcon.image = UI.symbol("xmark.octagon.fill", color: .systemRed, size: 22).image
            statusIcon.isHidden = false
            statusText.stringValue = "That didn't work: \(why)"
            statusText.textColor = .labelColor
            buttons.setViews([UI.button("Close", self, #selector(closeWindow)),
                              UI.button("Try Again", self, #selector(setUp), primary: true)], in: .trailing)
        }
        if let window { UI.fit(window) }
    }

    // MARK: - actions

    @objc private func closeWindow() { window?.performClose(nil) }

    @objc private func setUp() {
        // Statistics holds off its own trace from before the rule exists until the check is done.
        controller.sudoRuleVerifying = true
        let task = controller.addSudoRule { [weak self] outcome in
            guard let self else { return }
            self.task = nil
            switch outcome {
            case .done:
                self.verify()
            case .cancelled:
                self.releaseStatistics()
                self.stage = .intro
                self.render()
            case .failed(let why):
                self.releaseStatistics()
                self.stage = .failed(why)
                self.render()
            }
        }
        guard let task else {
            releaseStatistics()
            stage = .failed("another change to the rule is still going (Settings).")
            return render()
        }
        self.task = task
        stage = .working("Waiting for your password…")
        render()
    }

    private func releaseStatistics() {
        if controller.sudoRuleVerifying { controller.sudoRuleVerifying = false }
    }

    /// Start fs_usage through the new rule, the way Statistics will: sudo either runs it or says it wants a
    /// password. Stopped again right away. Meanwhile an open Statistics window waits with its own trace (the
    /// kernel allows one at a time).
    private func verify() {
        stage = .working("Checking that sudo accepts the rule…")
        render()
        let trace = ProgramTrace()
        check = trace
        trace.onState = { [weak self] state in self?.checked(state) }
        // Two limits, each tied to this check: waiting for an earlier trace to end (sudo's own limit ends it
        // within its 40 s), then, once this one's fs_usage starts, waiting for its first record.
        arm(after: TimeInterval(SudoRule.sudoTimeout + 10), for: trace, "an earlier fs_usage did not end")
        var launched = false
        trace.onLaunch = { [weak self, weak trace] in   // its first run only: later runs don't extend the limit
            guard let self, let trace, !launched else { return }
            launched = true
            self.arm(after: TimeInterval(SudoRule.sudoTimeout), for: trace, "fs_usage did not start tracing within \(SudoRule.sudoTimeout) seconds")
        }
        trace.start()   // no SSD devices given: only whether it runs
    }

    private func arm(after seconds: TimeInterval, for trace: ProgramTrace, _ why: String) {
        checkTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak trace] in
            MainActor.assumeIsolated {
                guard let self, let trace, self.check === trace else { return }
                self.checked(.failed(why))
            }
        }
        checkTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func checked(_ state: ProgramTrace.State) {
        guard check != nil else { return }
        switch state {
        case .starting: return
        case .running:
            stage = .done
            controller.sudoRuleTried(works: true)
        case .needsSetup:
            let why = check?.refusal.map { " sudo said: \($0)." } ?? ""
            stage = .failed("sudo didn't run fs_usage through the rule.\(why) Check that /etc/sudoers includes /etc/sudoers.d.")
            controller.sudoRuleTried(works: false, refusal: check?.refusal)
        case .failed(let why):
            stage = .failed(why)
        }
        endCheck()
        releaseStatistics()
        render()
    }

    private func endCheck() {
        checkTimeout?.cancel()
        checkTimeout = nil
        guard let check else { return }
        check.stop()
        self.check = nil
    }
}
