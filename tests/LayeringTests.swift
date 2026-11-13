// Layering tests. Registered in tests/main.swift.
//
// A click on another window shrinks the HUD to its bar, so the first thing to get wrong is
// which window that is. The shrinking and opening are in the Collapse suite below.
import Cocoa

private typealias W = HUDPanel.ScreenWindow

private func window(_ id: Int, pid: pid_t = 50, layer: Int = 0, alpha: Double = 1,
                    _ bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> W {
    W(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
}

let layeringSuite = Suite("Layering") { t in
    let at = CGPoint(x: 10, y: 10)
    func clicked(_ list: [W], hud: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> Int? {
        HUDPanel.windowToStepBehind(at: at, in: list, own: 7, hud: hud, screen: CGSize(width: 100, height: 100))
    }

    t.expectEqual(clicked([window(1), window(2)]), 1, "the frontmost window under the click")
    t.expectEqual(clicked([window(1, CGRect(x: 50, y: 50, width: 10, height: 10)), window(2)]), 2,
                  "a window elsewhere on screen wasn't clicked")
    t.expectEqual(clicked([window(1, pid: 7), window(2)]), 2, "never behind one of our own windows")
    t.expectEqual(clicked([window(1, layer: 25), window(2)]), 2, "a screen-sized overlay lets the click through")
    t.expect(clicked([window(1, layer: 101, CGRect(x: 0, y: 0, width: 40, height: 40)), window(2)]) == nil,
             "a menu or popover took the click: the window under it wasn't clicked")
    t.expectEqual(clicked([window(1, CGRect(x: 0, y: 0, width: 40, height: 40)), window(2, layer: 3, CGRect(x: 0, y: 0, width: 40, height: 40))]), 1,
                  "a palette behind the clicked window doesn't matter")
    t.expectEqual(clicked([window(1, alpha: 0), window(2)]), 2, "an invisible window is looked through")
    t.expect(clicked([window(1, layer: -2147483603)]) == nil, "the desktop is no window to go behind")
    t.expect(clicked([]) == nil, "nothing there")

    let farHUD = CGRect(x: 500, y: 500, width: 100, height: 100)
    t.expect(clicked([window(1)], hud: farHUD) == nil, "a window clear of the HUD doesn't sink it")
    t.expect(clicked([window(1), window(2, CGRect(x: 0, y: 0, width: 900, height: 900))], hud: farHUD) == nil,
             "only the window clicked counts, not a bigger one under it")

    func forward(minimized: Bool = false, visible: Bool = false, active: Bool = false) -> Bool {
        Controller.shouldComeForward(minimized: minimized, visible: visible, active: active)
    }
    t.expect(forward(visible: true), "up, even if behind a window: comes forward")
    t.expect(forward(active: true), "reading with no window up: comes forward")
    t.expect(!forward(), "closed with nothing to read: nothing to bring")
    t.expect(!forward(minimized: true, visible: true, active: true), "put away with Hide: stays away")

    // The menu bar icon is an explicit "show me": it brings the HUD up whatever hid it.
    typealias S = Controller.Summon
    func summon(built: Bool = true, minimized: Bool = false, visible: Bool = false) -> S {
        Controller.summonAction(built: built, minimized: minimized, visible: visible)
    }
    t.expect(summon(visible: false) == S.reopen, "hid itself after a reading: icon brings it back")
    t.expect(summon(minimized: true, visible: false) == S.reopen, "put away with Hide: icon still brings it back")
    t.expect(summon(visible: true) == S.forward, "up, maybe behind a window: comes to the front")
    t.expect(summon(built: false) == S.nothing, "nothing ever read: no window to show")

}

// The cure for a window the window server keeps on another desktop is a new one, as a
// restart gives (Chris, 11-08: fixes "work" right after an install, then fail later).
let rebuildSuite = Suite("Rebuild") { t in
    _ = NSApplication.shared
    let hud = Controller(listens: false)
    hud.buildWindowIfNeeded()
    let old = hud.panel!
    old.setFrame(NSRect(x: 100, y: 120, width: 520, height: 300), display: false)
    hud.rebuildWindow()
    t.expect(hud.panel !== old, "a new window")
    t.expectEqual(hud.panel.frame, old.frame, "in the same place and size")
    t.expect(!old.isVisible, "the old one is gone")
    t.expect(hud.panel.isVisible, "the new one is up")
    t.expect(hud.panel.collectionBehavior.contains(.canJoinAllSpaces), "the new one joins every desktop")
    hud.rebuildWindow()
    t.expect(hud.panel.isVisible, "and again, without the first one's watchers in the way")
}

// A click on a window under the HUD shrinks it to its top bar, still over everything
// (Chris, 11-13); a click on the bar, a reading or the menu bar icon opens it again.
let collapseSuite = Suite("Collapse") { t in
    _ = NSApplication.shared
    let hud = Controller(listens: false)
    hud.buildWindowIfNeeded()
    let panel = hud.panel!
    panel.setFrame(NSRect(x: 100, y: 120, width: 520, height: 300), display: false)
    let open = panel.frame
    let body = panel.body!
    let inside = body.frame.size
    hud.sourceBadge.text = "placerville-powersports"
    hud.sourceBadge.isLink = true
    hud.textView.string = "The text being read sits here, under the bar."

    panel.collapse()
    t.expect(panel.isCollapsed, "shrunk")
    t.expectEqual(panel.frame, NSRect(x: 100, y: open.maxY - HUDPanel.barHeight, width: 520, height: HUDPanel.barHeight),
                  "to the bar, top edge where it was")
    t.expectEqual(panel.level, .floating, "still over every window")
    t.expectEqual(body.frame.size, inside, "what's in it is not squeezed")
    t.expectEqual(body.frame.maxY, HUDPanel.barHeight, "and hangs from the top, so the bar is what shows")
    for b in [hud.replayBtn!, hud.pauseBtn!, hud.speedBtn!, hud.skipBtn!, hud.hideBtn!, hud.sourceBadge!] as [NSView] {
        let f = b.convert(b.bounds, to: nil)
        t.expect(f.minY >= 0 && f.maxY <= HUDPanel.barHeight, "\(type(of: b)) at \(f.minX) is inside the bar")
    }
    t.expect(hud.sourceBadge.frame.maxX <= hud.replayBtn.frame.minX, "the pill stops before the buttons")
    t.expectEqual(panel.fullFrame, open, "it knows where it opens back to")
    panel.collapse()
    t.expectEqual(panel.fullFrame, open, "shrinking twice keeps the first size")

    panel.expand()
    t.expect(!panel.isCollapsed, "opened")
    t.expectEqual(panel.frame, open, "to the size and place it had")
    t.expectEqual(body.frame, panel.contentView!.bounds, "filling the window again")
    t.expectEqual(panel.minSize.height, 260, "and it can't be dragged smaller than before")

    panel.collapse()
    panel.comeForward()
    t.expectEqual(panel.frame, open, "a reading or the menu bar icon opens it")

    panel.collapse()
    hud.rebuildWindow()
    t.expectEqual(hud.panel.frame, open, "a new window for a shrunk one comes up open")
    t.expect(!hud.panel.isCollapsed, "and is not shrunk")

    t.expectEqual(Controller.icon("❚❚ Pause"), "❚❚", "pause is its mark alone")
    t.expectEqual(Controller.icon("▶ Resume"), "▶", "so is resume")
    t.expectEqual(Controller.icon("✕ Close"), "⌫", "the reply window's close doesn't look like Hide")
    hud.panel.retire()
}
