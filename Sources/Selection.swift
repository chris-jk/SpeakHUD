import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// ---------------------------------------------------------------------------
// Reading the text you've highlighted in whatever app is frontmost.
// ---------------------------------------------------------------------------

enum Selection {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility" prompt. Returns true if already trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Selected text from the frontmost app, or nil if there is none (or we're untrusted).
    static func current() -> String? {
        guard isTrusted else { return nil }
        return viaAccessibility() ?? viaSynthesizedCopy()
    }

    /// The clean path: ask the focused UI element for its selection. Doesn't touch
    /// the clipboard, but plenty of apps (Chrome, some terminals) don't implement it.
    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)   // never hang on a wedged app
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID()
        else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let s = selected as? String
        else { return nil }
        return nonEmpty(s)
    }

    /// The fallback: press ⌘C for the user and put their clipboard back afterwards.
    private static func viaSynthesizedCopy() -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return nil }
        // Set flags explicitly: the user is still holding the trigger hotkey's modifiers,
        // and we must not deliver ⌃⌥⌘C to the target app.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Nothing selected means ⌘C is a no-op and changeCount never moves.
        var waitedMs = 0
        while pb.changeCount == before && waitedMs < 300 { usleep(10_000); waitedMs += 10 }
        guard pb.changeCount != before else { return nil }

        let copied = pb.string(forType: .string)
        restore(saved, to: pb)
        return copied.flatMap(nonEmpty)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { types[t] = item.data(forType: t) }
            return types
        }
    }

    private static func restore(_ snap: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let items = snap.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in types { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
