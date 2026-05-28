import AppKit
import SwiftUI
import QuartzCore

/// Owns one blur NSWindow per offending window. Each blur is permanently
/// at `.statusBar` level (above all `.normal` windows so click-raises
/// can't lift the source above it — no flicker), but the blur's content
/// is shaped each tick by a `CAShapeLayer` mask computed from the live
/// window stacking order.
///
/// The mask path is: source window's bounds, minus the intersection with
/// every window that's above the source in z-order (in CG screen
/// coordinates, then translated to window-local + Y-flipped for the
/// layer). Filled with even-odd rule so each occluder's intersection
/// cancels out of the source rect, leaving exactly the region of the
/// source that's currently visible to the user.
///
/// Consequences:
///   - Fully visible source → mask covers source bounds → full blur
///   - Partially occluded → mask is shaped to the still-visible region →
///     blur only covers what the user can actually see
///   - Fully occluded → mask is empty → blur draws nothing
///   - User clicks source → source raises within `.normal` → still
///     below `.statusBar` → no flicker
///   - User clicks Planning Center → Planning Center comes to the top
///     of `.normal` → next mask tick subtracts it from the source's
///     visible region → blur retracts from that area, Planning Center
///     is uncovered
@MainActor
final class BlurOverlayManager {
    private struct Overlay {
        let window: NSWindow
        let category: String
        let sourceApp: String?
        let maskLayer: CAShapeLayer
    }
    private var overlays: [UInt32: Overlay] = [:]
    private var dockTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var mouseMonitor: Any?

    /// Browser chrome heights (title bar + tab bar + URL bar). The blur
    /// is inset from the top by this amount so the user can still
    /// navigate, change URL, close tabs, etc.
    private static let chromeInsets: [String: CGFloat] = [
        "Google Chrome": 110,
        "Chromium": 110,
        "Arc": 90,
        "Safari": 80,
        "Safari Technology Preview": 80,
        "Firefox": 110,
        "Brave Browser": 110,
        "Microsoft Edge": 110,
    ]

    func show(forWindowID windowID: UInt32, category: String, app: String?) {
        if overlays[windowID] != nil {
            reposition(forWindowID: windowID, app: app)
            return
        }
        guard let initialBounds = lookupSourceBoundsAndOccluders(for: windowID).source else {
            NSLog("ValueGuard: could not look up bounds for windowID \(windowID); skipping overlay")
            return
        }
        let frame = withChromeInsetAndFlip(initialBounds, app: app)
        let (window, mask) = makeOverlayWindow(frame: frame, category: category, app: app)
        overlays[windowID] = Overlay(window: window, category: category, sourceApp: app, maskLayer: mask)
        applyVisibility(windowID: windowID, app: app)
        ensureDockingActive()
    }

    /// Refresh the mask and bounds. Called by the flag tick, mouse-down
    /// monitor, workspace activation, and the steady-state timer.
    func reposition(forWindowID windowID: UInt32, app: String?) {
        guard overlays[windowID] != nil else { return }
        applyVisibility(windowID: windowID, app: app)
    }

    func dismiss(forWindowID windowID: UInt32) {
        guard let entry = overlays.removeValue(forKey: windowID) else { return }
        entry.window.orderOut(nil)
        if overlays.isEmpty { stopDocking() }
    }

    func dismissAll() {
        for (_, entry) in overlays { entry.window.orderOut(nil) }
        overlays.removeAll()
        stopDocking()
    }

    /// Core logic: compute the source's visible region, set the window
    /// bounds to match, set the mask path to the visible region.
    private func applyVisibility(windowID: UInt32, app: String?) {
        guard let entry = overlays[windowID] else { return }
        let (sourceBoundsCG, occluders) = lookupSourceBoundsAndOccluders(for: windowID)
        guard let sourceBoundsCG else {
            // Source window is gone (closed, minimized, on another space).
            dismiss(forWindowID: windowID)
            return
        }
        let resolvedApp = app ?? entry.sourceApp
        // Inset the bounds by the browser chrome height so the URL bar /
        // tabs / traffic-light controls stay interactive.
        let insetCG = applyChromeInset(sourceBoundsCG, app: resolvedApp)
        let nsFrame = withChromeInsetAndFlip(sourceBoundsCG, app: resolvedApp)
        if entry.window.frame != nsFrame {
            entry.window.setFrame(nsFrame, display: false)
        }
        // Compute visible region path in window-local layer coords.
        let path = computeVisibleRegionPath(
            sourceBoundsCG: insetCG,
            occluders: occluders,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        entry.maskLayer.path = path
        if !entry.window.isVisible {
            entry.window.orderFront(nil)
        }
    }

    private func redockAll() {
        for (wid, entry) in overlays {
            applyVisibility(windowID: wid, app: entry.sourceApp)
        }
    }

    // MARK: - CGWindowList traversal

    /// Walk the on-screen window list in front-to-back order. Every window
    /// encountered before the target windowID is an occluder of it. Skip
    /// windows owned by this process (our own blur windows).
    private func lookupSourceBoundsAndOccluders(for windowID: UInt32) -> (source: CGRect?, occluders: [CGRect]) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return (nil, [])
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var occluders: [CGRect] = []
        for entry in list {
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if pid == ownPid { continue }
            let wid = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            if !CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect) { continue }
            if wid == windowID {
                return (rect, occluders)
            } else {
                occluders.append(rect)
            }
        }
        return (nil, occluders)
    }

    // MARK: - Coordinate / inset helpers

    private func applyChromeInset(_ bounds: CGRect, app: String?) -> CGRect {
        let inset = app.flatMap { Self.chromeInsets[$0] } ?? 0
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + inset,
            width: bounds.size.width,
            height: bounds.size.height - inset
        )
    }

    /// Take CG screen coords (top-left origin), apply chrome inset, and
    /// convert to NSWindow coords (bottom-left origin).
    ///
    /// Multi-display rule: NSWindow's global y origin lives at the bottom
    /// of the *primary* screen's frame.maxY in CG-flipped space. So the
    /// correct global flip is always against the primary screen, not the
    /// screen the source window happens to be on. (Source-window bounds
    /// from CGWindowList are already in the unified global CG top-left
    /// space — they don't need per-screen adjustment.) The primary
    /// screen is the one whose `frame.origin == .zero`, not necessarily
    /// `NSScreen.screens.first`.
    private func withChromeInsetAndFlip(_ boundsCG: CGRect, app: String?) -> CGRect {
        let inset = applyChromeInset(boundsCG, app: app)
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens.first
        guard let primary else { return inset }
        let flippedY = primary.frame.height - inset.origin.y - inset.height
        return CGRect(x: inset.origin.x, y: flippedY, width: inset.width, height: inset.height)
    }

    // MARK: - Visible region path

    /// Build the mask path: source rectangle XOR each occluder's
    /// intersection with the source. Even-odd fill rule means each
    /// occluder rect cancels out of the source rect, leaving the still-
    /// visible region.
    ///
    /// Returned path is in window-local coordinates with Y flipped to
    /// match the contentView layer's bottom-left origin.
    private func computeVisibleRegionPath(
        sourceBoundsCG: CGRect,
        occluders: [CGRect],
        ownPID: Int32
    ) -> CGPath {
        let path = CGMutablePath()
        // Translate so source origin → (0, 0). This puts everything in
        // window-local CG (top-left) coords.
        let translate = CGAffineTransform(
            translationX: -sourceBoundsCG.origin.x,
            y: -sourceBoundsCG.origin.y
        )
        let localSource = sourceBoundsCG.applying(translate)
        path.addRect(localSource)
        for occluder in occluders {
            let intersection = sourceBoundsCG.intersection(occluder)
            if intersection.isNull || intersection.isEmpty { continue }
            let localOccluder = intersection.applying(translate)
            path.addRect(localOccluder)
        }
        // Flip Y: layer coords are bottom-left, our path is top-left.
        // y_layer = height - y_cg, so transform is (a=1, b=0, c=0, d=-1, tx=0, ty=height).
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceBoundsCG.height)
        return path.copy(using: &flip) ?? path
    }

    // MARK: - Lifecycle

    private func ensureDockingActive() {
        if dockTimer == nil {
            // 100 ms steady-state refresh (catches window moves, resizes,
            // Mission Control activity, etc.).
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.redockAll() }
            }
        }
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.redockAll() }
            }
        }
        // Global mouse-down: on every click anywhere, recompute the mask
        // on the next runloop tick (so OS has finished raising the
        // clicked window before we measure z-order).
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in self?.redockAll() }
                }
            }
        }
    }

    private func stopDocking() {
        dockTimer?.invalidate()
        dockTimer = nil
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    // MARK: - Window construction

    private func makeOverlayWindow(frame: CGRect, category: String, app: String?) -> (NSWindow, CAShapeLayer) {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hostView = NSHostingView(rootView: BlurOverlayContent(
            category: category,
            app: app
        ))
        hostView.autoresizingMask = [.width, .height]
        hostView.frame = NSRect(origin: .zero, size: frame.size)
        hostView.wantsLayer = true

        // Even-odd path → source rect XOR each occluder rect = visible region.
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = hostView.bounds
        mask.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        hostView.layer?.mask = mask

        window.contentView = hostView
        window.setFrame(frame, display: true)
        NSLog("ValueGuard: created masked blur for \(category) in \(app ?? "?")")
        return (window, mask)
    }
}

private struct BlurOverlayContent: View {
    let category: String
    let app: String?

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.45)
            VStack(spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white)
                Text(category)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("You asked ValueGuard to filter this.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.88))
                Text("Navigate away from this content to dismiss.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(40)
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
