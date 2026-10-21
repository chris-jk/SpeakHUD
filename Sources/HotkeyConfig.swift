import Foundation
import Carbon.HIToolbox

// ---------------------------------------------------------------------------
// Global hotkey + background agent (read the selection from anywhere)
// ---------------------------------------------------------------------------

// Stored at ~/.config/speakhud/config.json so you can set your own combo.
// Set SPEAKHUD_CONFIG_DIR to point at a different dir (used by tests).
enum HotkeyConfig {
    static let defaultSpec = "ctrl+opt+s"
    static let dirEnv = "SPEAKHUD_CONFIG_DIR"
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment[dirEnv], !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return NSString(string: "~/.config/speakhud").expandingTildeInPath
    }
    static var path: String { dir + "/config.json" }

    /// The combo to use, and why it isn't yours when the file is broken. A missing file
    /// is not a problem (you just haven't picked one); anything unusable in a file that
    /// exists is, because otherwise your edit is silently ignored.
    struct Loaded: Equatable {
        let spec: String
        let problem: String?
    }

    static func load() -> Loaded {
        let fallback = { (why: String) in Loaded(spec: defaultSpec, problem: why) }
        guard FileManager.default.fileExists(atPath: path) else { return Loaded(spec: defaultSpec, problem: nil) }
        guard let data = FileManager.default.contents(atPath: path) else { return fallback("can't be read") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return fallback("isn't valid JSON") }
        guard let obj = json as? [String: Any] else { return fallback("isn't a JSON object") }
        guard let value = obj["hotkey"] else { return fallback("has no \"hotkey\" setting") }
        guard let hk = (value as? String)?.trimmingCharacters(in: .whitespaces), !hk.isEmpty else {
            return fallback("\"hotkey\" isn't a non-empty string")
        }
        guard parseHotkey(hk) != nil else {
            return fallback("hotkey \"\(hk)\" isn't a valid combo (need ≥1 modifier + a key)")
        }
        return Loaded(spec: hk, problem: nil)
    }

    @discardableResult
    static func save(_ spec: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = "{\n  \"hotkey\": \"\(spec)\"\n}\n"
        return (try? json.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Write the default only if there's no file yet — never over one you're editing,
    /// broken or not.
    @discardableResult
    static func ensureFile() -> Bool {
        FileManager.default.fileExists(atPath: path) || save(defaultSpec)
    }

    /// "ctrl+opt+s" → "⌃⌥S", in the order macOS menus draw modifiers.
    static func label(_ spec: String) -> String {
        var mods = Set<String>(), key = ""
        for raw in spec.lowercased().split(separator: "+") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": mods.insert("⌘")
            case "ctrl", "control", "⌃": mods.insert("⌃")
            case "opt", "option", "alt", "⌥": mods.insert("⌥")
            case "shift", "⇧": mods.insert("⇧")
            case let k: key = k
            }
        }
        let isFKey = key.count > 1 && key.hasPrefix("f") && key.dropFirst().allSatisfy(\.isNumber)
        let shown = key.count == 1 || isFKey ? key.uppercased() : key.capitalized
        return ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains).joined() + shown
    }
}

// `--set-hotkey`: save the combo, then restart the agent so it takes effect. Says what
// actually happened at each step instead of "hotkey set" regardless. The launchctl call
// is injected so the decision is testable without touching the live LaunchAgent.
enum SetHotkey {
    static let agentLabel = "com.chris.speakhud.agent"
    /// What `launchctl kickstart` said. launchctl exits 113 when the label isn't loaded.
    struct Kick: Equatable {
        let status: Int32
        let output: String
    }
    static let notLoadedStatus: Int32 = 113

    struct Outcome: Equatable {
        let message: String
        let exitCode: Int32
    }

    static func run(_ spec: String,
                    save: (String) -> Bool = { HotkeyConfig.save($0) },
                    kick: () throws -> Kick = kickAgent) -> Outcome {
        guard save(spec) else {
            return Outcome(message: "error: couldn't save \(spec) to \(HotkeyConfig.path) — nothing changed", exitCode: 1)
        }
        let result: Kick
        do { result = try kick() } catch {
            return Outcome(message: "error: saved \(spec), but couldn't run launchctl to restart the agent: \(error.localizedDescription)",
                           exitCode: 1)
        }
        let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.status {
        case 0:
            return Outcome(message: "hotkey set to \(spec) — agent restarted", exitCode: 0)
        case notLoadedStatus:
            return Outcome(message: "hotkey saved as \(spec); agent not running, takes effect when it starts", exitCode: 0)
        default:
            return Outcome(message: "error: saved \(spec), but restarting the agent failed (launchctl exit \(result.status))"
                                    + (said.isEmpty ? "" : ": \(said)"),
                           exitCode: 1)
        }
    }

    /// The real restart. Only `Main` calls this; tests inject their own.
    static func kickAgent() throws -> Kick {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Kick(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

// Human combo like "ctrl+opt+s" -> (Carbon keycode, modifier mask).
let keyCodeMap: [String: UInt32] = [
    "a":0x00,"s":0x01,"d":0x02,"f":0x03,"h":0x04,"g":0x05,"z":0x06,"x":0x07,"c":0x08,
    "v":0x09,"b":0x0B,"q":0x0C,"w":0x0D,"e":0x0E,"r":0x0F,"y":0x10,"t":0x11,"o":0x1F,
    "u":0x20,"i":0x22,"p":0x23,"l":0x25,"j":0x26,"k":0x28,"n":0x2D,"m":0x2E,
    "1":0x12,"2":0x13,"3":0x14,"4":0x15,"5":0x17,"6":0x16,"7":0x1A,"8":0x1C,"9":0x19,"0":0x1D,
    "space":0x31,"return":0x24,"tab":0x30,
    "f1":0x7A,"f2":0x78,"f3":0x63,"f4":0x76,"f5":0x60,"f6":0x61,"f7":0x62,"f8":0x64,
    "f9":0x65,"f10":0x6D,"f11":0x67,"f12":0x6F,
]

func parseHotkey(_ spec: String) -> (keyCode: UInt32, mods: UInt32)? {
    var mods: UInt32 = 0
    var key: String?
    for raw in spec.lowercased().split(separator: "+") {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
        case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
        case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
        case "shift", "⇧": mods |= UInt32(shiftKey)
        case let other: key = other
        }
    }
    guard let k = key, let code = keyCodeMap[k], mods != 0 else { return nil }   // need ≥1 modifier
    return (code, mods)
}
