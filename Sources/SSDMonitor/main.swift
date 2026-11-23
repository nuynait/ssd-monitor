import AppKit

// Menu bar only (LSUIElement in Info.plist): no Dock icon, no main window.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
