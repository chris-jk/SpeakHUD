import Cocoa

// Menu-bar settings surface for the agent: read clipboard, toggle the Claude Code
// integration, and pick the global hotkey — all without a Dock icon or window.
final class MenuController: NSObject, NSMenuDelegate {
    let agent: Agent
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var readTurnsItem: NSMenuItem!
    var claudeItem: NSMenuItem!
    var codexItem: NSMenuItem!
    var opencodeItem: NSMenuItem!
    var axItem: NSMenuItem!
    var hudItem: NSMenuItem!
    let hotkeyPresets = [("⌃⌥S", "ctrl+opt+s"), ("⌃⌥R", "ctrl+opt+r"),
                         ("⌃⌥Space", "ctrl+opt+space"), ("⌘⌥S", "cmd+opt+s")]
    var hotkeyItems: [NSMenuItem] = []
    var hotkeyWarning: NSMenuItem!
    var micItem: NSMenuItem!
    var audioItem: NSMenuItem!
    var voicesItem: NSMenuItem!
    var listenItem: NSMenuItem!
    var obeyItem: NSMenuItem!
    var awayItem: NSMenuItem!
    var pairItem: NSMenuItem!
    var phoneNote: NSMenuItem!
    private var menu: NSMenu!

    init(_ agent: Agent) {
        self.agent = agent
        super.init()
        build()
        // Hiding via the panel's own button has to move the menu item too. Only the
        // visibility bits: the hook check compares whole files, so it waits for the menu.
        agent.hud.onVisibilityChange = { [weak self] in self?.refreshVisibility() }
        agent.onAwayChange = { [weak self] in self?.refresh() }   // the phone can switch it too
    }

    private func build() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // so a disabled Pause While Recording (pre-14) stays disabled
        // First item, because when the HUD is hidden this is what you came here for.
        hudItem = item("Show HUD", #selector(toggleHUD))
        hudItem.keyEquivalent = "h"
        hudItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(hudItem)
        menu.addItem(item("Read Clipboard Aloud", #selector(readClipboard)))
        menu.addItem(.separator())

        readTurnsItem = item("Read Responses Aloud", #selector(toggleReadTurns))
        readTurnsItem.toolTip = "One switch for all of them. Off: no tool's turns are read; the switches below stay as they are"
        menu.addItem(readTurnsItem)
        claudeItem = item("Read Claude Code Responses Aloud", #selector(toggleClaude))
        menu.addItem(claudeItem)
        codexItem = item("Read Codex CLI Responses Aloud", #selector(toggleCodex))
        menu.addItem(codexItem)
        opencodeItem = item("Read OpenCode Responses Aloud", #selector(toggleOpenCode))
        menu.addItem(opencodeItem)

        micItem = item("Pause While Recording", #selector(toggleMicHold))
        if #available(macOS 14.0, *) {
            micItem.toolTip = "Hold speech while another app uses the microphone"
        } else {
            micItem.isEnabled = false
            micItem.toolTip = "Needs macOS 14 or later"
        }
        menu.addItem(micItem)

        audioItem = item("Wait While Audio Plays", #selector(toggleAudioHold))
        if #available(macOS 14.2, *) {
            audioItem.toolTip = "Hold speech while another app is making sound, and go on when it stops"
        } else {
            audioItem.isEnabled = false
            audioItem.toolTip = "Needs macOS 14.2 or later"
        }
        menu.addItem(audioItem)

        voicesItem = item("A Voice per Project", #selector(toggleVoices))
        voicesItem.toolTip = "Read each terminal's turns in a voice of its own, so you can tell them apart by ear"
        menu.addItem(voicesItem)

        listenItem = item("Listen After Reading", #selector(toggleListen))
        if agent.hud.canListen {
            listenItem.toolTip = "After a Claude Code turn is read, open the mic and send what you say back to its terminal. Say nothing and it closes."
        } else {
            listenItem.isEnabled = false
            listenItem.toolTip = "Needs macOS 26 or later"
        }
        menu.addItem(listenItem)

        obeyItem = item("Listen While Reading", #selector(toggleObey))
        if agent.hud.canListen {
            obeyItem.toolTip = "While a turn is being read, say: again, later, skip, pause, go on, stop everything. The Mac's own voice is cancelled out of the mic."
        } else {
            obeyItem.isEnabled = false
            obeyItem.toolTip = "Needs macOS 26 or later"
        }
        menu.addItem(obeyItem)

        let hk = NSMenu()
        hk.autoenablesItems = false   // keep the warning line disabled
        // Only shown while config.json is broken; the tooltip says how.
        hotkeyWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyWarning.isEnabled = false
        hk.addItem(hotkeyWarning)
        for (label, spec) in hotkeyPresets {
            let it = item(label, #selector(pickHotkey(_:))); it.representedObject = spec
            hk.addItem(it); hotkeyItems.append(it)
        }
        hk.addItem(.separator())
        hk.addItem(item("Edit Config File…", #selector(openHotkeyConfig)))
        let hkParent = NSMenuItem(title: "Global Hotkey", action: nil, keyEquivalent: "")
        hkParent.submenu = hk
        menu.addItem(hkParent)

        let ph = NSMenu()
        ph.autoenablesItems = false   // keep the note, and an unset-up Away, disabled
        awayItem = item("Away: Turns Go to My Phone", #selector(toggleAway))
        awayItem.toolTip = "Finished turns are pushed to your phone instead of read aloud, no mic opens, and the Mac stays awake."
        ph.addItem(awayItem)
        pairItem = item("Pair a Phone…", #selector(pairPhone))
        ph.addItem(pairItem)
        // Only shown until phone.json exists.
        phoneNote = NSMenuItem(title: "Not set up — run: speak-hud --setup-phone", action: nil, keyEquivalent: "")
        phoneNote.isEnabled = false
        ph.addItem(phoneNote)
        let phParent = NSMenuItem(title: "Phone", action: nil, keyEquivalent: "")
        phParent.submenu = ph
        menu.addItem(phParent)

        // Only surfaced when we can't read selections yet — otherwise it's noise.
        axItem = item("Grant Accessibility Access…", #selector(grantAccessibility))
        menu.addItem(axItem)

        menu.addItem(.separator())
        menu.addItem(item("SpeakHUD on GitHub", #selector(openGitHub)))
        menu.addItem(item("Quit SpeakHUD", #selector(quit)))
        self.menu = menu
        statusItem.menu = menu
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(statusClicked)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
    }

    /// Away, the menu bar's phone is its own off switch: a click brings you back to the
    /// Mac without opening the menu or the phone. Right-click or ⌥-click still opens it.
    /// Only reached while Away: otherwise the item has its menu and AppKit opens that.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if !wantsMenu, let phone = agent.phone, phone.away {
            phone.setAway(false)
            agent.hud.bringForward()
            refresh()
            return
        }
        // Popped up, not borrowed through statusItem.menu: opening the menu refreshes it,
        // and the refresh takes that away again while Away.
        if let btn = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 5), in: btn)
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// Clicking the icon also fetches a HUD lost behind a window, with the menu open over it.
    func menuWillOpen(_ menu: NSMenu) { agent.hud.summon() }

    private func refresh() {
        refreshVisibility()
        refreshHook()
        axItem.isHidden = Selection.isTrusted
        let loaded = HotkeyConfig.load()
        for it in hotkeyItems { it.state = (it.representedObject as? String == loaded.spec) ? .on : .off }
        hotkeyWarning.isHidden = loaded.problem == nil
        hotkeyWarning.title = "⚠ config.json invalid — "
            + (agent.registeredSpec.map { "using \(HotkeyConfig.label($0))" } ?? "no hotkey registered")
        hotkeyWarning.toolTip = loaded.problem.map { "\(HotkeyConfig.path) \($0)" }
        micItem.state = micItem.isEnabled && agent.hud.pauseWhileRecording ? .on : .off
        audioItem.state = audioItem.isEnabled && agent.hud.waitWhileAudioPlays ? .on : .off
        voicesItem.state = agent.hud.voicePerProject ? .on : .off
        readTurnsItem.state = agent.hud.readTurns ? .on : .off
        listenItem.state = agent.hud.listenAfterReading ? .on : .off
        obeyItem.state = agent.hud.listenWhileReading ? .on : .off
        let phone = agent.phone
        phoneNote.isHidden = phone != nil
        awayItem.isEnabled = phone != nil
        awayItem.state = phone?.away == true ? .on : .off
        pairItem.isEnabled = phone?.config.pairLink != nil
        pairItem.toolTip = phone != nil && phone?.config.pairLink == nil
            ? "phone.json has no url: set the address your phone reaches this Mac at" : nil
    }

    private func refreshVisibility() {
        let hidden = !agent.hud.isPanelVisible
        hudItem.title = hidden ? "Show HUD" : "Hide HUD"
        // A hollow icon is the standing reminder that the panel is only hidden,
        // not gone — otherwise a hidden HUD is indistinguishable from a broken one.
        if let btn = statusItem.button {
            // Away, nothing is read aloud: a phone in the menu bar says why it's quiet.
            if agent.phone?.away == true,
               let phone = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right",
                                   accessibilityDescription: "SpeakHUD (away: turns go to your phone)") {
                btn.image = phone
                btn.toolTip = "Away: turns go to your phone. Click to come back; right-click for the menu."
                statusItem.menu = nil   // so a click reaches statusClicked
                return
            }
            btn.toolTip = nil
            statusItem.menu = menu
            btn.image = NSImage(systemSymbolName: hidden ? "speaker.wave.2" : "speaker.wave.2.fill",
                                accessibilityDescription: hidden ? "SpeakHUD (hidden)" : "SpeakHUD")
        }
    }

    /// The Codex check runs a Python script (about a fifth of a second), too slow for the
    /// menu's opening: it shows the last answer and the item updates when the new one is in.
    private var codexStatus: String?
    private var codexChecking = false

    private func refreshHook() {
        if let codex = codexStatus { showCodex(codex) }
        if !codexChecking {
            codexChecking = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let codex = CodexHook.run("status")
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.codexChecking = false
                    self.codexStatus = codex
                    self.showCodex(codex)
                }
            }
        }
        opencodeItem.state = OpenCodeHook.installed ? .on : .off
        opencodeItem.toolTip = "Reads finished OpenCode turns. Restart OpenCode after changing this setting."
        let hook = ClaudeHook.check()
        claudeItem.title = hook.status == .stale ? "Read Claude Code Responses Aloud — Repair"
                                                 : "Read Claude Code Responses Aloud"
        switch hook.status {
        case .installed:    claudeItem.state = .on
        case .stale:        claudeItem.state = .mixed    // "–": present but broken
        case .notInstalled: claudeItem.state = .off
        }
        claudeItem.toolTip = hook.problems.isEmpty ? nil
            : hook.status == .stale ? "Needs repair: " + hook.problems.joined(separator: "; ") + ". Click to reinstall."
            : hook.problems.joined(separator: "; ")
    }

    private func showCodex(_ codex: String) {
        codexItem.title = codex.hasPrefix("stale") ? "Read Codex CLI Responses Aloud — Repair"
                                                  : "Read Codex CLI Responses Aloud"
        codexItem.state = codex == "installed" ? .on : codex.hasPrefix("stale") ? .mixed : .off
        codexItem.toolTip = codex == "installed" ? "Reads finished Codex CLI turns. Restart Codex after changing this setting."
                                                : codex + ". Restart Codex after enabling."
    }

    /// Do what the item said when the menu opened. Opening the menu already summoned the
    /// HUD, so "Show HUD" read as a toggle would hide the HUD that click just brought up.
    @objc private func toggleHUD() {
        if hudItem.title == "Show HUD" { agent.hud.summon() } else { agent.hud.toggleMinimized() }
    }
    @objc private func toggleCodex() {
        let result = CodexHook.run(CodexHook.run("status") == "installed" ? "remove" : "install")
        if result.hasPrefix("error") {
            let alert = NSAlert()
            alert.messageText = "Codex CLI integration"
            alert.informativeText = result
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }
    @objc private func toggleOpenCode() {
        let result = OpenCodeHook.installed ? OpenCodeHook.remove() : OpenCodeHook.install()
        if result.hasPrefix("error") {
            let alert = NSAlert()
            alert.messageText = "OpenCode integration"
            alert.informativeText = result
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }
    @objc private func readClipboard() { agent.readClipboard() }
    @objc private func toggleClaude() {
        // Installed -> remove. Stale -> reinstall (a repair, not an uninstall). Off -> install.
        let result = ClaudeHook.status() == .installed ? ClaudeHook.remove() : ClaudeHook.install()
        if result.hasPrefix("error") {
            let alert = NSAlert()
            alert.messageText = "Claude Code hook"
            alert.informativeText = result
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }
    @objc private func grantAccessibility() {
        if !Selection.requestTrust() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        refresh()
    }
    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        HotkeyConfig.save(spec)
        agent.registerReadHotKey()   // re-register live; no restart needed
        refresh()
    }
    @objc private func toggleMicHold() {
        agent.hud.pauseWhileRecording.toggle()
        refresh()
    }
    @objc private func toggleAudioHold() {
        agent.hud.waitWhileAudioPlays.toggle()
        refresh()
    }
    @objc private func toggleReadTurns() {
        agent.hud.readTurns.toggle()
        refresh()
    }
    @objc private func toggleVoices() {
        agent.hud.voicePerProject.toggle()
        refresh()
    }
    @objc private func toggleListen() {
        agent.hud.setListenAfterReading(!agent.hud.listenAfterReading) { [weak self] in
            self?.cantListen("Listen After Reading", $0)
        }
        refresh()
    }
    @objc private func toggleObey() {
        agent.hud.setListenWhileReading(!agent.hud.listenWhileReading) { [weak self] in
            self?.cantListen("Listen While Reading", $0)
        }
        refresh()
    }
    private func cantListen(_ setting: String, _ why: String) {
        let alert = NSAlert()
        alert.messageText = setting
        alert.informativeText = "Can't listen: \(why)."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        refresh()
    }
    @objc private func toggleAway() {
        guard let phone = agent.phone else { return }
        phone.setAway(!phone.away)
        refresh()
    }
    @objc private func pairPhone() {
        guard let link = agent.phone?.config.pairLink else { return }
        let alert = NSAlert()
        alert.messageText = "Pair a phone"
        alert.informativeText = "Point the phone's camera at this while it's on your tailnet. The link is the key to your terminals: don't share it."
        if let qr = PhonePair.qr(link, side: 240) {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
            view.image = qr
            alert.accessoryView = view
        }
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Link")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }
    @objc private func openHotkeyConfig() {
        HotkeyConfig.ensureFile()   // create it if missing; never overwrite a broken one you're fixing
        NSWorkspace.shared.open(URL(fileURLWithPath: HotkeyConfig.path))
    }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/chris-jk/SpeakHUD")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
