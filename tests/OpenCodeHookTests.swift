// OpenCodeHook tests. Registered in tests/main.swift. A temp dir via SPEAKHUD_OPENCODE_DIR,
// never the real ~/.config/opencode.
import Foundation

let openCodeHookSuite = Suite("OpenCodeHook") { t in
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "speakhud-opencode-\(UUID().uuidString)"
    let source = URL(fileURLWithPath: root + "/src.js")
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    try? "export const SpeakHUD = 1\n".write(to: source, atomically: true, encoding: .utf8)
    setenv("SPEAKHUD_OPENCODE_DIR", root + "/opencode", 1)
    defer { unsetenv("SPEAKHUD_OPENCODE_DIR"); try? fm.removeItem(atPath: root) }

    t.expect(!OpenCodeHook.installed, "off before install")
    t.expectEqual(OpenCodeHook.install(from: source), "installed", "install copies the plugin in")
    t.expect(OpenCodeHook.installed, "on after install")
    t.expectEqual(OpenCodeHook.install(from: source), "installed", "a second install replaces it")
    t.expectEqual(OpenCodeHook.remove(), "removed", "remove deletes the plugin")
    t.expect(!OpenCodeHook.installed, "off after remove")
    t.expectEqual(OpenCodeHook.remove(), "removed", "removing when off is fine")
    t.expect(OpenCodeHook.install(from: nil).hasPrefix("error"), "no source is an error, not a crash")
}
