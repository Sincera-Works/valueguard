import AppKit
import SwiftUI

@MainActor
final class OnboardingWindow {
    private var window: NSWindow?
    private var state: OnboardingState?
    var onFinish: (() -> Void)?

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let state = OnboardingState()
        self.state = state
        let view = OnboardingView(state: state) { [weak self] in
            self?.dismiss()
        }
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Set up ValueGuard"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        state = nil
        onFinish?()
    }
}
