// Per-window blur overlay binary.
//
// Launched by valueguard with positional flags:
//   blur_overlay show --x N --y N --width N --height N [--label "text"]
//
// CGWindowBounds coordinates (which the daemon passes) use a top-left origin;
// NSWindow uses bottom-left. We flip Y here so the overlay lands exactly on
// the window the daemon flagged.
//
// Exits cleanly on SIGTERM. The daemon sends SIGTERM when hysteresis clears
// or the underlying window disappears.

import Cocoa

let usage = "usage: blur_overlay show --x N --y N --width N --height N [--label \"text\"]"

var x: CGFloat? = nil
var y: CGFloat? = nil
var w: CGFloat? = nil
var h: CGFloat? = nil
var label: String = ""

var iter = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iter.next() {
    switch arg {
    case "show":
        continue
    case "--x":
        if let v = iter.next(), let n = Double(v) { x = CGFloat(n) }
    case "--y":
        if let v = iter.next(), let n = Double(v) { y = CGFloat(n) }
    case "--width":
        if let v = iter.next(), let n = Double(v) { w = CGFloat(n) }
    case "--height":
        if let v = iter.next(), let n = Double(v) { h = CGFloat(n) }
    case "--label":
        label = iter.next() ?? ""
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown arg \(arg)\n".utf8))
        exit(2)
    }
}

guard let x = x, let y = y, let w = w, let h = h else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

// Find which screen contains this rect's top-left corner; coord conversion is
// per-screen on multi-monitor setups.
let topLeft = NSPoint(x: x, y: y)
let screen = NSScreen.screens.first { NSPointInRect(topLeft, $0.frame) } ?? NSScreen.main!
let flippedY = screen.frame.height - y - h
let rect = NSRect(x: x, y: flippedY, width: w, height: h)

final class BlurWindow: NSWindow {
    init(rect: NSRect, label: String) {
        super.init(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: rect.size))
        host.wantsLayer = true

        let effect = NSVisualEffectView(frame: host.bounds)
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        // alphaValue MUST stay 1.0 — anything lower disables blur rendering and
        // the result is flat gray. Use the tint overlay below for darkening instead.
        effect.alphaValue = 1.0
        effect.autoresizingMask = [.width, .height]
        host.addSubview(effect)

        let tint = NSView(frame: host.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        tint.autoresizingMask = [.width, .height]
        host.addSubview(tint)

        if !label.isEmpty {
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .center
            labelView.font = NSFont.systemFont(ofSize: 18, weight: .medium)
            labelView.textColor = .white
            labelView.drawsBackground = false
            labelView.isBezeled = false
            labelView.isEditable = false
            labelView.frame = NSRect(
                x: 12,
                y: rect.height - 44,
                width: rect.width - 24,
                height: 28
            )
            labelView.autoresizingMask = [.width, .minYMargin]
            host.addSubview(labelView)
        }

        contentView = host
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = BlurWindow(rect: rect, label: label)
window.orderFrontRegardless()

// Handle SIGTERM cleanly. signal(SIGTERM, SIG_IGN) is required first so the
// DispatchSource takes precedence over the default-die handler.
signal(SIGTERM, SIG_IGN)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTerm.setEventHandler {
    exit(0)
}
sigTerm.resume()

app.run()
