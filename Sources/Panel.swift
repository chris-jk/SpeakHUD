import Cocoa

// ---------------------------------------------------------------------------
// Source identity: a stable color per project, so four terminals are four
// colors you learn rather than four names you have to read.
// ---------------------------------------------------------------------------

enum Accent {
    // Yellow and red are omitted: one is illegible, the other reads as an error.
    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemPink, .systemIndigo, .systemBrown,
    ]
    /// djb2 rather than Swift's `hashValue`, whose seed is randomized per process —
    /// a project would otherwise change color every time the agent restarted.
    static func color(for source: String) -> NSColor {
        var h: UInt64 = 5381
        for byte in source.utf8 { h = (h &* 33) &+ UInt64(byte) }
        return palette[Int(h % UInt64(palette.count))]
    }

    /// The terminal's own frame color ("#rrggbb" from the item's origin), when it has
    /// one: then the pill is the color of the window it goes back to.
    static func frame(_ hex: String?) -> NSColor? {
        guard let hex = hex, hex.count == 7, hex.hasPrefix("#"),
              let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// A colored pill naming whoever is speaking. When the item knows where it came
/// from, the pill is a link: an arrow, a hand cursor, and a click goes there.
final class SourceBadge: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .systemBlue { didSet { needsDisplay = true } }
    /// Filled with the accent instead of tinted by it. For an accent that is the
    /// terminal's frame color: a solid pill is the same swatch as that window's title bar.
    var solid = false { didSet { needsDisplay = true } }
    var isLink = false {
        didSet {
            needsDisplay = true
            toolTip = isLink ? "Go to this terminal" : nil
            window?.invalidateCursorRects(for: self)
        }
    }
    var onClick: () -> Void = {}

    private static let arrow = " ↗"

    private static let dot: CGFloat = 7
    private static let padX: CGFloat = 11
    private static let gap: CGFloat = 7
    private static let maxWidth: CGFloat = 260
    static let height: CGFloat = 24

    private var textAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail   // long repo names shouldn't stretch the pill
        return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: ink,
                .paragraphStyle: p]
    }

    /// The name and dot: the accent itself on a tinted pill, black or white on a solid
    /// one, whichever the accent leaves readable.
    private var ink: NSColor {
        guard solid, let c = accent.usingColorSpace(.sRGB) else { return accent }
        let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luma > 0.5 ? NSColor(white: 0, alpha: 0.85) : .white
    }

    /// The arrow is drawn after the name, not as part of it: a session's title is often
    /// too long to fit, and cut off as one string the arrow would be the first thing to go.
    private var arrowWidth: CGFloat {
        isLink ? ceil((Self.arrow as NSString).size(withAttributes: textAttrs).width) : 0
    }

    override var intrinsicContentSize: NSSize {
        let w = ceil((text as NSString).size(withAttributes: textAttrs).width) + arrowWidth
        return NSSize(width: min(w + Self.padX * 2 + Self.dot + Self.gap, Self.maxWidth),
                      height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        accent.withAlphaComponent(solid ? 1 : 0.18).setFill(); pill.fill()
        accent.withAlphaComponent(solid ? 1 : 0.5).setStroke(); pill.lineWidth = 1; pill.stroke()

        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.padX, y: (r.height - Self.dot) / 2,
                                    width: Self.dot, height: Self.dot)).fill()

        let attrs = textAttrs
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let x = Self.padX + Self.dot + Self.gap
        let y = (r.height - size.height) / 2
        let w = min(ceil(size.width), r.width - x - Self.padX - arrowWidth)
        s.draw(in: NSRect(x: x, y: y, width: w, height: size.height), withAttributes: attrs)
        if isLink {
            (Self.arrow as NSString).draw(at: NSPoint(x: x + w, y: y), withAttributes: attrs)
        }
    }

    override func resetCursorRects() { if isLink { addCursorRect(bounds, cursor: .pointingHand) } }

    /// Whether a click at this window location lands on a live link.
    func takesClick(at locationInWindow: NSPoint) -> Bool {
        isLink && !isHiddenOrHasHiddenAncestor && bounds.contains(convert(locationInWindow, from: nil))
    }
}

/// After the pill takes you to a terminal: dim everything else for a moment and ring
/// that window in the pill's color. Four terminals tiled together look alike, and the
/// one that just came forward isn't obvious.
final class Spotlight {
    static let dim: CGFloat = 0.4
    static let ring: CGFloat = 5
    static let hold: TimeInterval = 0.9
    static let fade: TimeInterval = 0.4

    /// AppleScript's bounds count down from the top of the main screen; AppKit's count
    /// up from its bottom.
    static func flipped(_ r: NSRect, mainHeight: CGFloat? = nil) -> NSRect {
        let h = mainHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private final class Shade: NSView {
        var hole = NSRect.zero
        var color = NSColor.white

        override func draw(_ dirtyRect: NSRect) {
            let shade = NSBezierPath(rect: bounds)
            shade.append(NSBezierPath(roundedRect: hole, xRadius: 10, yRadius: 10))
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(Spotlight.dim).setFill(); shade.fill()
            // Inside the window's edge: a ring outside it is cut off at the screen's.
            let inset = Spotlight.ring / 2
            let ring = NSBezierPath(roundedRect: hole.insetBy(dx: inset, dy: inset), xRadius: 10, yRadius: 10)
            ring.lineWidth = Spotlight.ring
            color.setStroke(); ring.stroke()
        }
    }

    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var showing = 0   // bumped per show, so a finished fade can't take down a newer one

    init() {
        // The jump may have switched desktops: start the moment over once it lands.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.windows.isEmpty else { return }
            self.windows.forEach { $0.alphaValue = 1 }
            self.linger()
        }
    }

    /// `target` in AppKit screen coordinates. One shade per screen; clicks pass through.
    func show(around target: NSRect, color: NSColor) {
        clear()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.level = .floating   // over app windows, under the menu bar and Dock
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let shade = Shade(frame: NSRect(origin: .zero, size: screen.frame.size))
            shade.hole = target.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            shade.color = color
            w.contentView = shade
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        linger()
    }

    private func linger() {
        showing += 1
        let mine = showing
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fade
                self.windows.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                if self?.showing == mine { self?.clear() }
            })
        }
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

/// SpeakHUD runs as an accessory app: no Dock icon, and no menu bar to own an Edit
/// menu. ⌘C is normally delivered *by* that menu, so without one a selection in the
/// transcript looks copyable but silently isn't. Route the few editing keys the panel
/// needs straight into the responder chain instead.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // …or it never sees a keystroke at all

    /// One entry of the window server's list, which runs front to back.
    struct ScreenWindow {
        let id: Int
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    /// The ordinary window a click landed on, if the HUD should step behind it. Layer 0 is
    /// where app windows live: above it are overlays that let clicks through, below it is
    /// the desktop, which is no window to go behind. A window that doesn't touch the HUD
    /// isn't one: going behind it would only sink the HUD under whatever else is open.
    /// `point` and `hud` count down from the top of the main screen.
    static func windowToStepBehind(at point: CGPoint, in windows: [ScreenWindow], own: pid_t, hud: CGRect) -> Int? {
        guard let clicked = windows.first(where: {
            $0.pid != own && $0.layer == 0 && $0.alpha > 0 && $0.bounds.contains(point)
        }), clicked.bounds.intersects(hud) else { return nil }
        return clicked.id
    }

    private static func screenWindows() -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return (list as? [[String: Any]] ?? []).compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let box = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: box) else { return nil }
            return ScreenWindow(id: id, pid: pid_t(pid), layer: layer,
                                alpha: w[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
    }

    /// Sent behind a window by a click, until something brings it forward.
    var isBehind: Bool { level != .floating }

    /// Over every app window: where it sits to be read.
    func comeForward() {
        level = .floating
        orderFrontRegardless()
    }

    /// Just under one window, so the work in it shows and anything further back stays covered.
    func goBehind(window: Int) {
        level = .normal
        order(.below, relativeTo: window)
    }

    private var clickWatch: Any?

    /// A global monitor only sees clicks meant for other apps, so the HUD's own never get here.
    func watchClicks() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.clickedElsewhere()
        }
    }

    private func clickedElsewhere() {
        let point = NSEvent.mouseLocation
        // visibleFrame leaves out the menu bar and the Dock, which aren't windows being worked in.
        guard isVisible, !isBehind, NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }),
              let top = NSScreen.screens.first?.frame.height,
              let window = Self.windowToStepBehind(at: CGPoint(x: point.x, y: top - point.y), in: Self.screenWindows(),
                                                   own: ProcessInfo.processInfo.processIdentifier,
                                                   hud: Spotlight.flipped(frame, mainHeight: top))
        else { return }
        goBehind(window: window)
        onWentBehind()
    }

    var onWentBehind: () -> Void = {}

    /// The panel is deliberately non-activating, so it can appear mid-sentence without
    /// stealing focus from whatever you're typing in. The cost is that an inactive app
    /// receives no keyboard input at all — which is why selecting text and pressing ⌘C
    /// did nothing. Clicking the HUD is an unambiguous "I want to use this", so take
    /// focus at that point, and only then.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isBehind { comeForward() }   // the part still showing was clicked
        // The pill sits under the transparent title bar, which takes clicks there as
        // the start of a drag, and the first click on an inactive panel only focuses
        // it. Either way the pill itself would never see the click, so catch it here.
        if event.type == .leftMouseDown, let link = link, link.takesClick(at: event.locationInWindow) {
            // Active, so this app can hand activation on to the terminal (macOS 14+).
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            DispatchQueue.main.async { link.onClick() }
            return
        }
        if event.type == .leftMouseDown, !NSApp.isActive {
            focusDonor = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }

    /// The source pill, whose clicks are routed here rather than by hit-testing.
    weak var link: SourceBadge?

    /// Whoever we took focus from. NSApp.deactivate() alone just leaves this app
    /// frontmost with no windows, so the app has to be reactivated by name.
    private var focusDonor: NSRunningApplication?

    func returnFocus() {
        guard NSApp.isActive, let donor = focusDonor,
              donor.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        donor.activate(options: [])
        focusDonor = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default:  action = nil
        }
        if let action = action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
