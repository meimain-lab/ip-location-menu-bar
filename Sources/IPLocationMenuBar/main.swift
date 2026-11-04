import AppKit

// Top-level code runs on the main thread; make that explicit for the @MainActor delegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
