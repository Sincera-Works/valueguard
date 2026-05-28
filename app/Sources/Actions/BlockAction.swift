import Foundation

/// Hard-block intervention. For supported browsers, navigates the front
/// tab away to a blank page via AppleScript. For unsupported apps, no-op
/// (better to do nothing than to terminate apps the user didn't expect).
///
/// Block is by definition more disruptive than blur. Reserve it for
/// categories where the user has explicitly said "must not see."
enum BlockAction {
    static func run(app: String?, category: String) async {
        guard let app else { return }
        let script: String?
        switch app {
        case "Google Chrome", "Chromium", "Arc":
            script = """
            tell application "\(app)"
                if (count of windows) > 0 then
                    set URL of active tab of front window to "about:blank"
                end if
            end tell
            """
        case "Safari", "Safari Technology Preview":
            script = """
            tell application "\(app)"
                if (count of windows) > 0 then
                    set URL of current tab of front window to "about:blank"
                end if
            end tell
            """
        default:
            script = nil
        }
        guard let script else { return }
        await runAppleScript(script)
    }

    private static func runAppleScript(_ source: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let s = NSAppleScript(source: source)
                _ = s?.executeAndReturnError(&error)
                cont.resume()
            }
        }
    }
}
