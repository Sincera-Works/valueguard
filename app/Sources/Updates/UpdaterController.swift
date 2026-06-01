import AppKit
import Sparkle

/// Owns ValueGuard's Sparkle auto-updater and exposes the single action the rest
/// of the app needs: "check for updates now".
///
/// ## Why a wrapper at all
/// `SPUStandardUpdaterController` *is* the batteries-included Sparkle entry point
/// — it builds the updater, the standard (Cocoa) user driver, and wires them
/// together, reading every knob from `Info.plist` (`SUFeedURL`,
/// `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`). We
/// still wrap it for three small but real reasons:
///
/// 1. **Ownership & lifetime.** The controller must be retained for the lifetime
///    of the app or background checks silently stop. `AppDelegate` retains one
///    `UpdaterController`; that is the whole story.
/// 2. **Menubar isolation.** This is an `LSUIElement` accessory app with a
///    hand-built `NSMenu` (see `MenubarController`). There is no standard App
///    menu and no responder-chain `checkForUpdates(_:)` target for Sparkle's
///    menu-item validation to find. So instead of handing Sparkle's
///    first-responder action to a menu item, we expose a plain `checkForUpdates()`
///    closure the menubar can call directly.
/// 3. **A seam for the future.** If we later want a delegate (custom feed
///    selection, channels, gentle reminders), it lands here without touching the
///    menubar or app delegate.
///
/// ## Configuration lives in Info.plist, not here
/// The feed URL and the EdDSA public key are intentionally *not* set in code —
/// they live in `Info.plist` (generated from `project.yml`'s `info.properties`)
/// so there is exactly one source of truth and so the release pipeline and the
/// running app cannot drift apart. Until `SUPublicEDKey` is replaced from its
/// placeholder with the real `generate_keys` public key, Sparkle will refuse to
/// install any update because signature verification fails — which is the safe
/// default, not a bug.
///
/// ## Security note
/// Distribution is a direct-download, Developer-ID-signed + notarized DMG (not
/// the App Store), so Sparkle is the sanctioned update mechanism. Every update is
/// EdDSA-signed at release time (`sign_update`, key in the Keychain) and verified
/// here against `SUPublicEDKey` before it is ever run. The DMG is *also*
/// notarized, so Gatekeeper independently vets it on first launch.
@MainActor
final class UpdaterController {
    /// The standard Sparkle controller. Owns the updater + Cocoa user driver and
    /// pulls all configuration from `Info.plist`. Retained for the app's lifetime
    /// (via `AppDelegate`) so scheduled background checks keep running.
    private let controller: SPUStandardUpdaterController

    /// Builds and (optionally) starts the updater.
    ///
    /// - Parameter startingUpdater: Pass `true` for normal app launch so the
    ///   background scheduler comes online and honors `SUEnableAutomaticChecks` /
    ///   `SUScheduledCheckInterval` from `Info.plist`. The controller will, on
    ///   first run, ask the user whether to enable automatic checks. Pass `false`
    ///   only if you need to defer startup (we never do today).
    ///
    /// `SPUStandardUpdaterController` requires no delegates for our use; we pass
    /// `nil` for both the updater delegate and the user-driver delegate and rely
    /// entirely on the standard behavior plus `Info.plist` configuration.
    init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Triggers a *user-initiated* update check immediately, showing Sparkle's
    /// standard UI (progress, "you're up to date", or the update sheet). This is
    /// the action behind the menubar's "Check for Updates…" item.
    ///
    /// We call the updater directly rather than routing through Sparkle's
    /// first-responder `checkForUpdates(_:)` selector because this accessory app
    /// has no standard menu / responder chain for that action to validate against
    /// (see the type doc comment).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
