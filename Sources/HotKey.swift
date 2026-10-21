import Foundation
import Carbon.HIToolbox

// ---------------------------------------------------------------------------
// Global hotkeys. One Carbon handler for the whole process, dispatching on the
// hotkey id — installing a handler per feature would fire all of them on any key.
// ---------------------------------------------------------------------------

enum HotKeyAction: UInt32 { case read = 1, togglePause = 2, toggleHUD = 3 }

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private static let signature = OSType(0x53504b48)   // 'SPKH'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            if err == noErr { HotKeyCenter.shared.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ action: HotKeyAction, keyCode: UInt32, mods: UInt32,
                  handler: @escaping () -> Void) -> Bool {
        installHandler()
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        guard RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref = ref else { return false }
        refs[action.rawValue] = ref
        handlers[action.rawValue] = handler
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: action.rawValue)
    }
}
