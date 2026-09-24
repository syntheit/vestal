#if os(macOS)
import Carbon
import Foundation
import VestalCore

// MARK: - Built-in hotkey (Carbon)
//
// `RegisterEventHotKey` needs no Accessibility permission, unlike an event
// tap or a global NSEvent monitor. The key and modifiers come from
// VestalCore's `HotkeySpec` (parsed and tested on Linux). The system sends
// the hot key event to the application event target, which dispatches it on
// the main thread while the app runs its event loop. skhd and Karabiner keep
// working next to it; a key bound both here and there fires in both.

@MainActor
final class CarbonHotkeys: HotkeyRegistrar {
    /// "vstl": marks our hot key among any others in the app.
    private static let signature: OSType = 0x7673_746C

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    func register(_ spec: HotkeySpec?, action: @escaping @MainActor () -> Void) -> String? {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        self.action = nil
        guard let spec else { return nil }
        if handler == nil {
            // Once, for the life of the app (the app keeps this object).
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &type,
                                             Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "InstallEventHandler failed (\(status))" }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.macKeyCode, spec.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return status == OSStatus(eventHotKeyExistsErr)
                ? "another app has registered it"
                : "RegisterEventHotKey failed (\(status))"
        }
        hotKey = ref
        self.action = action
        return nil
    }

    fileprivate func pressed(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        action?()
    }
}

/// The Carbon event handler: a C function, so it finds the registrar through
/// `userData`.
private func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?,
                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let hotkeys = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
    // Carbon calls this on the main thread, from the app's event loop.
    MainActor.assumeIsolated { hotkeys.pressed(id) }
    return noErr
}
#endif
