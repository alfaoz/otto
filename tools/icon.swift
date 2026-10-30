// renders the otto icon: a dark squircle with the "ot/to" block monogram.
// usage: swift icon.swift <out.png> <size> [mode]
//   (no mode)       the app icon: the squircle at 80% of the canvas, as in the Dock
//   full            the squircle filling the canvas (the Chrome toolbar's "otto is filling" state, small extension icons)
//   pad <px>        the squircle inset by <px> on each side (chrome://extensions wants 96 px of art in 128)
//   glyph <#hex>    just the monogram in one color on nothing (the Chrome toolbar's resting icon)
// below 64 px the monogram is pixel-fitted: its size and position are nudged so its edges land on whole pixels.
import AppKit

let args = CommandLine.arguments
let out = args[1]
let size = CGFloat(Double(args[2]) ?? 1024)
let mode = args.count > 3 ? args[3] : "app"
let option = args.count > 4 ? args[4] : nil

// IBM Plex Mono SemiBold outlines, in font units as svg path data (y down, baseline at 0, advance 600)
let o = "M300 12Q241 12 194.5 -7Q148 -26 115.5 -61Q83 -96 65.5 -146Q48 -196 48 -258Q48 -320 65.5 -370Q83 -420 115.5 -455Q148 -490 194.5 -509Q241 -528 300 -528Q358 -528 405 -509Q452 -490 484.5 -455Q517 -420 534.5 -370Q552 -320 552 -258Q552 -196 534.5 -146Q517 -96 484.5 -61Q452 -26 405 -7Q358 12 300 12ZM300 -86Q355 -86 387 -119.5Q419 -153 419 -218V-298Q419 -363 387 -396.5Q355 -430 300 -430Q245 -430 213 -396.5Q181 -363 181 -298V-218Q181 -153 213 -119.5Q245 -86 300 -86Z"
let t = "M335 0Q261 0 226 -39Q191 -78 191 -140V-415H41V-516H143Q174 -516 187 -528.5Q200 -541 200 -573V-698H319V-516H529V-415H319V-101H529V0Z"

// appends svg path data (absolute M/L/H/V/Q/Z only) to p, through `map` from font units to pixels
func append(_ d: String, to p: CGMutablePath, map: (CGFloat, CGFloat) -> CGPoint) {
    var spaced = ""
    for ch in d { spaced += ch.isLetter ? " \(ch) " : ch == "-" ? " -" : String(ch) }
    let tokens = spaced.split(separator: " ").map(String.init)
    var i = 0, cmd: Character = "M", x: CGFloat = 0, y: CGFloat = 0
    func num() -> CGFloat { i += 1; return CGFloat(Double(tokens[i - 1])!) }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter {
            cmd = c; i += 1
            if c == "Z" { p.closeSubpath(); continue }
        }
        switch cmd {
        case "M": x = num(); y = num(); p.move(to: map(x, y)); cmd = "L"
        case "L": x = num(); y = num(); p.addLine(to: map(x, y))
        case "H": x = num(); p.addLine(to: map(x, y))
        case "V": y = num(); p.addLine(to: map(x, y))
        case "Q":
            let cx = num(), cy = num(); x = num(); y = num()
            p.addQuadCurve(to: map(x, y), control: map(cx, cy))
        default: fatalError("unsupported path command \(cmd)")
        }
    }
}

func hex(_ s: String) -> CGColor {
    let v = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

// monogram: "ot" over "to", one em (760 units) between baselines. its box is x 41...1152, y -698...772 (1111 x 1470)
func mark(k: CGFloat, cx: CGFloat, cy: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for (glyph, gx, gy) in [(o, 0.0, 0.0), (t, 600, 0), (t, 0, 760), (o, 600, 760)] as [(String, CGFloat, CGFloat)] {
        append(glyph, to: p) { x, y in CGPoint(x: cx + (x + gx - 596.5) * k, y: cy - (y + gy - 37) * k) }
    }
    return p
}

func bitmap(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The monogram's scale and centre, `fill` (a fraction of `box`'s height, or a range of them) at the middle of `box`.
/// Small icons try sizes in the range and sub-pixel shifts and keep the one with the fewest half-covered pixels.
func fit(_ box: CGRect, fill: ClosedRange<CGFloat>) -> (k: CGFloat, cx: CGFloat, cy: CGFloat) {
    let mid = (fill.lowerBound + fill.upperBound) / 2
    guard size < 64 else { return (box.height * mid / 1470, box.midX, box.midY) }
    var best: (score: CGFloat, k: CGFloat, cx: CGFloat, cy: CGFloat) = (.infinity, 0, 0, 0)
    for f in stride(from: fill.lowerBound, through: fill.upperBound + 0.0001, by: 0.01) {
        let k = box.height * f / 1470
        let (w, h) = (1111 * k, 1470 * k)
        for dx in stride(from: -0.5, through: 0.5, by: 0.125) {
            for dy in stride(from: -0.5, through: 0.5, by: 0.125) {
                let (cx, cy) = (box.midX + dx, box.midY + dy)
                // stays on the canvas
                guard cx - w / 2 >= -0.01, cx + w / 2 <= size + 0.01, cy - h / 2 >= -0.01, cy + h / 2 <= size + 0.01 else { continue }
                let rep = bitmap { ink($0, mark(k: k, cx: cx, cy: cy), .white) }
                var gray: CGFloat = 0, cover: CGFloat = 0
                let data = rep.bitmapData!
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        let a = CGFloat(data[y * rep.bytesPerRow + x * 4 + 3]) / 255
                        gray += 4 * a * (1 - a)
                        cover += a
                    }
                }
                // crisper wins; between equals, the bigger one
                let score = gray / max(cover, 1) - (f - fill.lowerBound) * 0.6
                if score < best.score { best = (score, k, cx, cy) }
            }
        }
    }
    return (best.k, best.cx, best.cy)
}

func ink(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath(using: .evenOdd)
}

let paper = CGColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 1)
let rep: NSBitmapImageRep
if mode == "glyph" {
    let at = fit(CGRect(x: 0, y: 0, width: size, height: size), fill: size < 64 ? 0.88...1.0 : 1.0...1.0)
    rep = bitmap { ink($0, mark(k: at.k, cx: at.cx, cy: at.cy), hex(option ?? "#474747")) }
} else {
    let inset = mode == "full" ? 0 : mode == "pad" ? CGFloat(Double(option ?? "") ?? 0) : size * 0.1
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let s = rect.width
    // small sizes fill more of the squircle so the letters stay legible
    let at = s < 40 ? fit(rect, fill: 0.8...0.88) : (k: s * 0.7 / 1470, cx: rect.midX, cy: rect.midY)
    rep = bitmap { ctx in
        let squircle = CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
        ctx.addPath(squircle)
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1), CGColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ink(ctx, mark(k: at.k, cx: at.cx, cy: at.cy), paper)
    }
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
