import AppKit
import Carbon.HIToolbox

/// A system-wide "panic" hotkey (⌃⌥⌘D) that instantly tears down any active
/// blur and snoozes further filtering for a short window.
///
/// Implemented with Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`: the Carbon route fires regardless of
/// which app is frontmost and needs no Accessibility permission, which is
/// essential here — when a blur is covering content the offending app (not
/// ValueGuard) is the active app, so an app-local key handler would never see
/// the keystroke.
@MainActor
final class EmergencyHotkey {
    /// ⌃⌥⌘D — three modifiers + a letter make accidental triggering unlikely.
    static let displayString = "⌃⌥⌘D"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func register() {
        guard hotKeyRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The C trampoline must be non-capturing, so it recovers `self` from
        // the userData pointer we hand to InstallEventHandler.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<EmergencyHotkey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in me.onTrigger() }
                return noErr
            },
            1, &spec, selfPtr, &handlerRef
        )
        guard installStatus == noErr else {
            NSLog("ValueGuard: InstallEventHandler failed (\(installStatus)); emergency hotkey unavailable — use the menubar 'Dismiss blur now' item")
            handlerRef = nil
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5647_4744 /* 'VGGD' */), id: 1)
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            // Most likely eventHotKeyExistsErr (-9878): the combo is already
            // claimed by another app. The menubar "Dismiss blur now" item is
            // the fallback. Tear down the just-installed handler so a later
            // register() starts clean.
            NSLog("ValueGuard: RegisterEventHotKey(⌃⌥⌘D) failed (\(regStatus)) — combo may be claimed by another app; use the menubar 'Dismiss blur now' item")
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
            hotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    // No deinit: this object is held for the whole app lifetime, and a class
    // deinit is nonisolated under Swift 5.10, so touching the Carbon event
    // target (UnregisterEventHotKey / RemoveEventHandler) from it could run
    // off the main thread. The OS reclaims the global hotkey on process exit;
    // for explicit teardown, call `unregister()` on the main actor.
}
