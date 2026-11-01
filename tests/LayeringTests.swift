// Layering tests. Registered in tests/main.swift.
//
// A click on another window sends the HUD behind that window, so the only thing to get
// wrong is which window that is. The going behind itself is the window server's.
import Cocoa

private typealias W = HUDPanel.ScreenWindow

private func window(_ id: Int, pid: pid_t = 50, layer: Int = 0, alpha: Double = 1,
                    _ bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> W {
    W(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
}

let layeringSuite = Suite("Layering") { t in
    let at = CGPoint(x: 10, y: 10)
    func clicked(_ list: [W], hud: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> Int? {
        HUDPanel.windowToStepBehind(at: at, in: list, own: 7, hud: hud)
    }

    t.expectEqual(clicked([window(1), window(2)]), 1, "the frontmost window under the click")
    t.expectEqual(clicked([window(1, CGRect(x: 50, y: 50, width: 10, height: 10)), window(2)]), 2,
                  "a window elsewhere on screen wasn't clicked")
    t.expectEqual(clicked([window(1, pid: 7), window(2)]), 2, "never behind one of our own windows")
    t.expectEqual(clicked([window(1, layer: 25), window(2)]), 2, "an overlay above the app windows is looked through")
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
}
