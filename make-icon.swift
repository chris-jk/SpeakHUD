// Renders AppIcon.icns for SpeakHUD: a white speaker-wave glyph on a purple
// gradient "squircle". Run via build.sh (needs sips + iconutil, both stock macOS).
import Cocoa

let masterSize: CGFloat = 1024

// Reliable tint: fill with the color, then keep only the glyph's alpha.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: image.size)
    r.fill()
    image.draw(in: r, from: r, operation: .destinationIn, fraction: 1.0)
    out.unlockFocus()
    return out
}

func renderMaster() -> NSImage {
    let size = NSSize(width: masterSize, height: masterSize)
    let img = NSImage(size: size)
    img.lockFocus()

    // Gradient squircle background.
    let rect = NSRect(origin: .zero, size: size)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: masterSize * 0.225, yRadius: masterSize * 0.225)
    squircle.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.40, green: 0.31, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.60, green: 0.32, blue: 0.92, alpha: 1),
    ])!
    grad.draw(in: rect, angle: -90)

    // Centered speaker glyph, tinted white.
    let cfg = NSImage.SymbolConfiguration(pointSize: masterSize * 0.46, weight: .semibold)
    if let base = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let glyph = tinted(base, .white)
        let gs = glyph.size
        let origin = NSPoint(x: (masterSize - gs.width) / 2, y: (masterSize - gs.height) / 2)
        glyph.draw(at: origin, from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 1.0)
    }

    img.unlockFocus()
    return img
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_master.png"
let master = renderMaster()
guard let tiff = master.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
