import Cocoa
import Carbon.HIToolbox

// Shared prefs domain so the speed setting is the same no matter how the reader
// was launched (double-click app, Claude Code hook, or the global hotkey).
// NB: the suite name must NOT equal the app's bundle id, or macOS rejects it.
let prefs = UserDefaults(suiteName: "com.chris.speakhud.shared") ?? .standard

// Text source priority: explicit arg → piped stdin (the Claude Code hook) →
// clipboard. The clipboard fallback is what makes the .app useful when launched
// on its own (double-click / Spotlight / a hotkey), where there's no stdin pipe.
func resolveText(_ args: [String]) -> String {
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--source" || a == "--origin" { i += 2; continue }   // flag + its value
        if a.hasPrefix("--") { i += 1; continue }
        if !a.isEmpty { return a }
        i += 1
    }
    // Only drain stdin when it's a pipe/file; reading an interactive TTY would block.
    if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
    }
    return NSPasteboard.general.string(forType: .string) ?? ""
}

// ---------------------------------------------------------------------------
// Entry point: dispatch on mode. Compiled out for tests (tests/run.sh builds with
// -D TESTING), so a test main can link the rest (Sources/) without launching the app.
// @main rather than top-level code, because Swift rejects top-level statements in
// any file but main.swift, even inside an inactive #if.
// ---------------------------------------------------------------------------
#if !TESTING
@main
enum Main {
    static func main() {
        let argv = CommandLine.arguments

        if let i = argv.firstIndex(of: "--set-hotkey") {
            guard i + 1 < argv.count, parseHotkey(argv[i + 1]) != nil else {
                FileHandle.standardError.write(
                    "usage: speak-hud --set-hotkey \"ctrl+opt+s\"  (need ≥1 modifier + a key)\n".data(using: .utf8)!)
                exit(2)
            }
            let outcome = SetHotkey.run(argv[i + 1])
            if outcome.exitCode == 0 {
                print(outcome.message)
            } else {
                FileHandle.standardError.write((outcome.message + "\n").data(using: .utf8)!)
            }
            exit(outcome.exitCode)
        }

        for (flag, action) in [("--setup-codex", "install"), ("--remove-codex", "remove"), ("--codex-status", "status")] {
            if argv.contains(flag) {
                let result = CodexHook.run(action)
                print(result)
                exit(result.hasPrefix("error") ? 1 : 0)
            }
        }
        if argv.contains("--setup-claude") || argv.contains("--remove-claude") {
            let r = argv.contains("--setup-claude") ? ClaudeHook.install() : ClaudeHook.remove()
            print(r); exit(r.hasPrefix("error") ? 1 : 0)
        }
        if argv.contains("--refresh-claude-files") {
            let r = ClaudeHook.refreshFiles()
            print(r); exit(r.hasPrefix("error") ? 1 : 0)
        }
        if argv.contains("--claude-status") {
            // "installed" | "stale: <why>" | "not installed" — build.sh matches on these.
            let c = ClaudeHook.check()
            print(c.problems.isEmpty ? c.status.rawValue
                                     : c.status.rawValue + ": " + c.problems.joined(separator: "; "))
            exit(0)
        }

        if argv.contains("--setup-phone") {
            let outcome = PhonePair.setup(argv)
            if outcome.exitCode == 0 {
                print(outcome.message)
            } else {
                FileHandle.standardError.write((outcome.message + "\n").data(using: .utf8)!)
            }
            exit(outcome.exitCode)
        }

        if argv.contains("--agent") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let agent = Agent()
            let agentDelegate = AgentDelegate(agent)
            app.delegate = agentDelegate          // handles double-click "reopen" -> read clipboard
            agent.run()
            let menuController = MenuController(agent)   // menu-bar settings surface
            _ = menuController
            app.run()
            exit(0)
        }

        // Default: a one-shot reader HUD. Used for `speak-hud "text"` and as the Claude
        // Code hook's fallback when the agent isn't running to serialize things for us.
        let text = resolveText(argv).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { exit(0) }

        var sourceName = "Claude Code"
        if let i = argv.firstIndex(of: "--source"), i + 1 < argv.count { sourceName = argv[i + 1] }
        var origin: Origin?
        if let i = argv.firstIndex(of: "--origin"), i + 1 < argv.count { origin = Origin(jsonString: argv[i + 1]) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, doesn't steal focus
        let controller = Controller(listens: false)
        controller.onIdle = { NSApp.terminate(nil) }
        controller.watchMic()
        controller.watchAudio()
        HotKeyCenter.shared.register(.togglePause,
                                     keyCode: UInt32(kVK_ANSI_P),
                                     mods: UInt32(controlKey | optionKey)) { [weak controller] in
            controller?.togglePause()
        }
        controller.enqueue(SpeechItem(text: text, source: sourceName, key: UUID().uuidString, created: Date(),
                                      origin: origin))
        app.run()
    }
}
#endif
