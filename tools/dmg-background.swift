// renders the DMG window's background: the icon's colors turned around, cream ground and black ink.
// usage: swift dmg-background.swift <out dir> <version>   → background.png (660×400) and background@2x.png
// Finder labels the icons in black on a picture, also in dark mode, so the ground stays light.
import AppKit

let args = CommandLine.arguments
let dir = URL(filePath: args[1])
let version = args[2]

// the window's content area; tools/dmg.py adds the title bar
let W: CGFloat = 660, H: CGFloat = 400
// where tools/dmg.py puts the icons (centers, from the top left)
let left = CGPoint(x: 190, y: 196), right = CGPoint(x: 470, y: 196)

let cream = NSColor(srgbRed: 0.941, green: 0.925, blue: 0.886, alpha: 1)
let ink = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1)

func font(_ size: CGFloat, _ weight: String) -> NSFont {
    NSFont(name: "IBMPlexMono-\(weight)", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
}

func text(_ s: String, _ f: NSFont, _ alpha: CGFloat, at p: CGPoint, right: Bool = false) {
    let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: ink.withAlphaComponent(alpha)])
    a.draw(at: CGPoint(x: right ? p.x - a.size().width : p.x, y: p.y))
}

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    // top-left origin, like Finder's icon positions
    base.cgContext.translateBy(x: 0, y: H)
    base.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)

    cream.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // from one icon to the other: a run of dots, the way a monospaced line would set it, then a chevron
    let y = left.y, from = left.x + 80, to = right.x - 80
    ink.withAlphaComponent(0.35).setFill()
    var x = from
    while x < to - 14 {
        NSRect(x: x, y: y - 1, width: 2, height: 2).fill()
        x += 8
    }
    ink.withAlphaComponent(0.6).setStroke()
    let chevron = NSBezierPath()
    chevron.lineWidth = 1.5
    chevron.lineCapStyle = .square
    chevron.move(to: CGPoint(x: to - 6, y: y - 6))
    chevron.line(to: CGPoint(x: to, y: y))
    chevron.line(to: CGPoint(x: to - 6, y: y + 6))
    chevron.stroke()

    text("otto", font(15, "SemiBold"), 1, at: CGPoint(x: 40, y: 34))
    text(version, font(11, "Regular"), 0.55, at: CGPoint(x: W - 40, y: 37), right: true)
    text("otto.alfaoz.dev", font(11, "Regular"), 0.55, at: CGPoint(x: 40, y: H - 52))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

render(scale: 1, to: dir.appending(path: "background.png"))
render(scale: 2, to: dir.appending(path: "background@2x.png"))
