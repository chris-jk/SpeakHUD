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
    func clicked(_ list: [W]) -> Int? { HUDPanel.clickedWindow(at: at, in: list, own: 7) }

    t.expectEqual(clicked([window(1), window(2)]), 1, "the frontmost window under the click")
    t.expectEqual(clicked([window(1, CGRect(x: 50, y: 50, width: 10, height: 10)), window(2)]), 2,
                  "a window elsewhere on screen wasn't clicked")
    t.expectEqual(clicked([window(1, pid: 7), window(2)]), 2, "never behind one of our own windows")
    t.expectEqual(clicked([window(1, layer: 25), window(2)]), 2, "an overlay above the app windows is looked through")
    t.expectEqual(clicked([window(1, alpha: 0), window(2)]), 2, "an invisible window is looked through")
    t.expect(clicked([window(1, layer: -2147483603)]) == nil, "the desktop is no window to go behind")
    t.expect(clicked([]) == nil, "nothing there")
}
