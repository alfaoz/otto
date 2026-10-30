import AppKit
import SwiftUI

/// Card brands' own logos (vector files in Resources/brands), so a saved card looks like the one in
/// your wallet: Visa's wordmark, Mastercard's circles, TROY's teal o.
enum BrandLogo {
    private static var cache: [String: NSImage] = [:]

    static func file(_ brand: String) -> String? {
        switch brand {
        case "Visa": "visa"
        case "Mastercard": "mastercard"
        case "American Express": "amex"
        case "Troy": "troy"
        case "Discover": "discover"
        case "JCB": "jcb"
        case "UnionPay": "unionpay"
        case "Diners Club": "diners"
        default: nil
        }
    }

    /// On a dark card, Discover and TROY have white-letter versions and Visa and Diners turn white.
    static func image(_ brand: String, onDark: Bool = false) -> NSImage? {
        guard let base = file(brand) else { return nil }
        let white = onDark && (brand == "Visa" || brand == "Diners Club")
        let name = onDark && (base == "discover" || base == "troy") ? "\(base)-white" : base
        let key = white ? "\(name)#white" : name
        if let i = cache[key] { return i }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "brands"),
              let i = NSImage(contentsOf: url) else { return nil }
        if white { i.isTemplate = true }
        cache[key] = i
        return i
    }

    /// how much room each logo takes, as a share of the card's width: wide wordmarks lie low, marks stand taller
    static func box(_ brand: String) -> CGSize {
        switch brand {
        case "Visa": CGSize(width: 0.25, height: 0.085)
        case "Mastercard": CGSize(width: 0.2, height: 0.124)
        case "American Express": CGSize(width: 0.15, height: 0.15)
        case "Troy": CGSize(width: 0.22, height: 0.1)
        case "Discover": CGSize(width: 0.3, height: 0.055)
        case "JCB": CGSize(width: 0.16, height: 0.123)
        case "UnionPay": CGSize(width: 0.19, height: 0.12)
        case "Diners Club": CGSize(width: 0.12, height: 0.12)
        default: CGSize(width: 0.12, height: 0.09)
        }
    }
}

/// A brand's logo fitted into a box, white (on a dark card) or in its own colors.
struct BrandLogoView: View {
    let brand: String
    var onDark = false
    let size: CGSize

    var body: some View {
        Group {
            if let img = BrandLogo.image(brand, onDark: onDark) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "creditcard")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.medium)
                    .foregroundStyle(onDark ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .trailing)
    }
}

/// The colors of each brand's card: a dark gradient and a glow in the brand's own color.
enum CardArt {
    struct Palette {
        let top: Color
        let bottom: Color
        let glow: Color
    }

    static func palette(_ brand: String) -> Palette {
        switch brand {
        case "Visa": Palette(top: hex(0x2C4BE0), bottom: hex(0x0A1458), glow: hex(0x7D96FF))
        case "Mastercard": Palette(top: hex(0x3B3B42), bottom: hex(0x0F0F12), glow: hex(0xFF7A1A))
        case "American Express": Palette(top: hex(0x1F5A92), bottom: hex(0x061A30), glow: hex(0x46A8FF))
        case "Troy": Palette(top: hex(0x3E4C55), bottom: hex(0x12181D), glow: hex(0x24B8C9))
        case "Discover": Palette(top: hex(0x3A3633), bottom: hex(0x121110), glow: hex(0xF48120))
        case "JCB": Palette(top: hex(0x253A57), bottom: hex(0x0B1220), glow: hex(0x3FA34D))
        case "UnionPay": Palette(top: hex(0x2C3442), bottom: hex(0x0E1218), glow: hex(0xE21836))
        case "Diners Club": Palette(top: hex(0x34404C), bottom: hex(0x12171C), glow: hex(0x4FA9E6))
        default: Palette(top: hex(0x4A4D55), bottom: hex(0x18191D), glow: hex(0x9AA0AA))
        }
    }

    /// the color the card's page washes in
    static func tint(_ brand: String) -> Color {
        let p = palette(brand)
        return brand == "Card" ? Color(white: 0.6) : p.glow.mix(with: p.top, by: 0.35)
    }

    static func hex(_ v: Int) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// A card as checkouts show it: the brand's real logo on a small white card. Sits in a square slot of
/// `size`, like the other entries' icons.
struct CardBadge: View {
    let brand: String
    var size: CGFloat = 28

    var body: some View {
        let w = size, h = (size * 0.68).rounded()
        let shape = RoundedRectangle(cornerRadius: max(2.5, size * 0.11), style: .continuous)
        ZStack {
            if brand == "American Express", let img = BrandLogo.image(brand) {
                // the Amex logo is itself a blue box
                shape.fill(CardArt.hex(0x016FD0))
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(h * 0.08)
            } else if BrandLogo.file(brand) != nil {
                shape.fill(.white)
                BrandLogoView(brand: brand, size: CGSize(width: w * 0.74, height: h * (brand == "Visa" || brand == "Discover" ? 0.36 : 0.62)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                shape.fill(LinearGradient(colors: [CardArt.hex(0x5A5E68), CardArt.hex(0x2A2C31)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "creditcard.fill").font(.system(size: h * 0.46, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.14), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.22), radius: max(1, size * 0.05), y: max(0.5, size * 0.025))
        .frame(width: size, height: size)
    }
}

/// A card as it looks in your hand, filled in live while you type: the brand's colors and logo, the
/// number with the digits still to come, the name, the expiry. Turns over to its back for the CVC,
/// and leans toward the pointer.
struct CardFace: View {
    let brand: String
    /// digits typed (or revealed); empty shows the saved last four, or placeholders
    let digits: String
    var last4: String?
    let title: String
    let holder: String
    let expiry: String
    /// what the back shows in the CVC box (dots unless it's being shown)
    let cvc: String
    var expired = false
    var back = false
    /// while editing, empty fields show what goes there
    var placeholders = true
    var width: CGFloat = 340

    @State private var pointer: CGPoint?

    private var height: CGFloat { (width / 1.586).rounded() }
    private var p: CardArt.Palette { CardArt.palette(brand) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: width * 0.048, style: .continuous) }

    var body: some View {
        let lean = pointer.map { CGSize(width: $0.x - 0.5, height: $0.y - 0.5) } ?? .zero
        ZStack {
            front.modifier(Turn(angle: back ? 180 : 0, front: true))
            backSide.modifier(Turn(angle: back ? 180 : 0, front: false))
        }
        .rotation3DEffect(.degrees(Double(-lean.height) * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(Double(lean.width) * 12), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .shadow(color: p.bottom.opacity(0.55), radius: 22, x: -lean.width * 14, y: 14 - lean.height * 8)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let at): pointer = CGPoint(x: at.x / width, y: at.y / height)
            case .ended: pointer = nil
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: back)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pointer)
        .animation(.easeInOut(duration: 0.35), value: brand)
    }

    // MARK: sides

    /// The card's body. Its glows and engraving are drawn over it and clipped to it, so they never
    /// change its size.
    private var plate: some View {
        shape
            .fill(LinearGradient(colors: [p.top, p.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: width, height: height)
            .overlay {
                ZStack {
                    Circle()
                        .fill(p.glow.opacity(0.55))
                        .frame(width: width * 0.95, height: width * 0.95)
                        .blur(radius: width * 0.13)
                        .offset(x: width * 0.42, y: -height * 0.55)
                    Circle()
                        .fill(p.glow.opacity(0.22))
                        .frame(width: width * 0.7, height: width * 0.7)
                        .blur(radius: width * 0.12)
                        .offset(x: -width * 0.38, y: height * 0.62)
                    // fine engraved rings, like a banknote's
                    ForEach(0..<16, id: \.self) { i in
                        Circle()
                            .stroke(.white.opacity(0.05 - Double(i) * 0.002), lineWidth: 0.6)
                            .frame(width: width * (0.22 + Double(i) * 0.075), height: width * (0.22 + Double(i) * 0.075))
                            .offset(x: width * 0.4, y: height * 0.42)
                    }
                    // the light on it, following the pointer
                    RadialGradient(colors: [.white.opacity(pointer == nil ? 0.08 : 0.2), .clear],
                                   center: UnitPoint(x: pointer?.x ?? 0.15, y: pointer?.y ?? 0.0),
                                   startRadius: 0, endRadius: width * 0.75)
                        .blendMode(.plusLighter)
                }
                .frame(width: width, height: height)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .white.opacity(0.14)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
    }

    private var front: some View {
        plate.overlay {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.isEmpty ? "new card" : title)
                        .font(.system(size: width * 0.046, weight: .semibold))
                        .foregroundStyle(.white.opacity(title.isEmpty ? 0.45 : 0.92))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if expired {
                        Text("EXPIRED")
                            .font(.system(size: width * 0.03, weight: .heavy))
                            .tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.red.opacity(0.85), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: width * 0.04) {
                    Chip(width: width * 0.135)
                    Image(systemName: "wave.3.right")
                        .font(.system(size: width * 0.052, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Text(numberLine)
                    .font(.system(size: width * 0.064, weight: .medium, design: .monospaced))
                    .shadow(color: .black.opacity(0.35), radius: 0.5, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: width * 0.05) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !holder.isEmpty || placeholders {
                            label("CARDHOLDER")
                            Text(holder.isEmpty ? "YOUR NAME" : holder.uppercased())
                                .font(.system(size: width * 0.038, weight: .medium))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(holder.isEmpty ? 0.4 : 0.95))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !expiry.isEmpty || placeholders {
                        VStack(alignment: .leading, spacing: 2) {
                            label("VALID THRU")
                            Text(expiry.isEmpty ? "MM/YY" : expiry)
                                .font(.system(size: width * 0.04, weight: .medium, design: .monospaced))
                                .foregroundStyle(expired ? AnyShapeStyle(Color(red: 1, green: 0.55, blue: 0.55)) : AnyShapeStyle(.white.opacity(expiry.isEmpty ? 0.4 : 0.95)))
                        }
                    }
                    // the brand's logo once the number shows which brand it is
                    let box = BrandLogo.box(brand)
                    if BrandLogo.file(brand) != nil {
                        BrandLogoView(brand: brand, onDark: true, size: CGSize(width: width * box.width, height: width * box.height))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .id(brand)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, width * 0.065)
            .padding(.vertical, width * 0.06)
        }
    }

    private var backSide: some View {
        plate.overlay {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                    .frame(height: height * 0.19)
                    .padding(.top, height * 0.11)
                HStack(alignment: .center, spacing: width * 0.025) {
                    // the signature strip
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.76)], startPoint: .leading, endPoint: .trailing))
                        .overlay {
                            // the strip's fine diagonal print
                            Canvas { ctx, size in
                                var lines = Path()
                                var x = -size.height
                                while x < size.width {
                                    lines.move(to: CGPoint(x: x, y: size.height))
                                    lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                                    x += 4
                                }
                                ctx.stroke(lines, with: .color(.black.opacity(0.045)), lineWidth: 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(cvc.isEmpty ? "•••" : cvc)
                        .font(.system(size: width * 0.05, weight: .semibold, design: .monospaced))
                        .italic()
                        .foregroundStyle(.black.opacity(0.82))
                        .contentTransition(.numericText())
                        .frame(width: width * 0.17, height: height * 0.15)
                        .background(.white, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(alignment: .top) {
                            label("CVC").offset(y: -height * 0.085)
                        }
                }
                .frame(height: height * 0.15)
                .padding(.horizontal, width * 0.065)
                .padding(.top, height * 0.16)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Text("agents fill it only after your Touch ID")
                        .font(.system(size: width * 0.027, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    let box = BrandLogo.box(brand)
                    if BrandLogo.file(brand) != nil {
                        BrandLogoView(brand: brand, onDark: true, size: CGSize(width: width * box.width * 0.8, height: width * box.height * 0.8))
                    }
                }
                .padding(.horizontal, width * 0.065)
                .padding(.bottom, width * 0.055)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: width * 0.022, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.55))
    }

    /// the typed digits, then dim dots for the ones still to come, grouped the brand's way
    private var numberLine: AttributedString {
        let d = digits.filter(\.isNumber)
        let count: Int
        let text: String
        if !d.isEmpty {
            count = CardInput.lengths(d).first { $0 >= d.count } ?? d.count
            text = d + String(repeating: "•", count: max(0, count - d.count))
        } else {
            let tail = last4 ?? ""
            count = brand == "American Express" ? 15 : 16
            text = String(repeating: "•", count: count - tail.count) + tail
        }
        var out = AttributedString()
        var i = 0
        for (n, size) in CardInput.groups(count).enumerated() {
            if n > 0 { out += AttributedString(" ") }
            for ch in text.dropFirst(i).prefix(size) {
                var a = AttributedString(ch == "•" ? "●" : String(ch))
                if ch == "•" {
                    a.foregroundColor = .white.opacity(0.45)
                    a.font = .system(size: width * 0.036, weight: .regular, design: .monospaced)
                    a.baselineOffset = width * 0.011
                    a.kern = width * 0.0225
                } else {
                    a.foregroundColor = .white
                }
                out += a
            }
            i += size
        }
        return out
    }

    /// One side of the card, turned around the vertical axis; it shows only while facing you.
    private struct Turn: ViewModifier, Animatable {
        var angle: Double
        let front: Bool

        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }

        func body(content: Content) -> some View {
            content
                .opacity((angle < 90) == front ? 1 : 0)
                .rotation3DEffect(.degrees(front ? angle : angle - 180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        }
    }

    /// The gold contact chip.
    private struct Chip: View {
        let width: CGFloat

        var body: some View {
            let h = width * 0.76
            let shape = RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
            shape
                .fill(LinearGradient(colors: [CardArt.hex(0xF3DFA2), CardArt.hex(0xC9A55A), CardArt.hex(0xE8CF8A)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Canvas { ctx, size in
                        var lines = Path()
                        let w = size.width, h = size.height
                        for y in [0.33, 0.66] {
                            lines.move(to: CGPoint(x: 0, y: h * y))
                            lines.addLine(to: CGPoint(x: w * 0.36, y: h * y))
                            lines.move(to: CGPoint(x: w * 0.64, y: h * y))
                            lines.addLine(to: CGPoint(x: w, y: h * y))
                        }
                        lines.move(to: CGPoint(x: w * 0.5, y: 0))
                        lines.addLine(to: CGPoint(x: w * 0.5, y: h * 0.22))
                        lines.move(to: CGPoint(x: w * 0.5, y: h * 0.78))
                        lines.addLine(to: CGPoint(x: w * 0.5, y: h))
                        lines.addRoundedRect(in: CGRect(x: w * 0.36, y: h * 0.22, width: w * 0.28, height: h * 0.56), cornerSize: CGSize(width: 3, height: 3))
                        ctx.stroke(lines, with: .color(.black.opacity(0.28)), lineWidth: 0.8)
                    }
                }
                .overlay { shape.strokeBorder(.black.opacity(0.2), lineWidth: 0.5) }
                .frame(width: width, height: h)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
    }
}

/// What the card fields accept, formatted as the user types: only digits where digits go, grouped
/// the brand's way and no longer than the brand's numbers.
enum CardInput {
    static func digits(_ s: String) -> String { s.filter { $0.isASCII && $0.isNumber } }

    /// how long the brand's numbers are; typing stops at the last
    static func lengths(_ digits: String) -> [Int] {
        switch CardInfo.brand(of: digits) {
        case "American Express": [15]
        case "Diners Club": digits.hasPrefix("36") ? [14] : [16]
        case "UnionPay": [16, 17, 18, 19]
        case "Card": Array(12...19)
        default: [16]
        }
    }

    static func groups(_ count: Int) -> [Int] {
        switch count {
        case 15: [4, 6, 5]
        case 14: [4, 6, 4]
        default: Array(repeating: 4, count: count / 4) + (count % 4 > 0 ? [count % 4] : [])
        }
    }

    static func number(_ s: String) -> String {
        let d = digits(s)
        return CardInfo.grouped(String(d.prefix(lengths(d).last ?? 19)))
    }

    enum Status: Equatable {
        case empty, short(Int), good, bad
    }

    static func status(_ s: String) -> Status {
        let d = digits(s)
        guard !d.isEmpty else { return .empty }
        let ls = lengths(d)
        if ls.contains(d.count), CardInfo.luhn(d) { return .good }
        if d.count >= ls.last ?? 19 { return .bad }
        return .short((ls.first { $0 > d.count } ?? d.count) - d.count)
    }

    /// MM/YY as it's typed: the slash comes by itself, a 4 means April (04/), 13 can't be a month, and
    /// pasted 12/2034 or 122034 become 12/34
    static func expiry(_ new: String, old: String) -> String {
        let parts = new.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).map(String.init)
        var d: String
        if parts.count >= 2, parts[1].count == 4 {
            d = parts[0] + parts[1].suffix(2)
        } else if parts.count >= 2, parts[0].count == 1 {
            d = "0" + parts[0] + parts[1]
        } else {
            d = parts.joined()
            if parts.count == 1, d.count == 6 { d = String(d.prefix(2) + d.suffix(2)) }
        }
        if let f = d.first, ("2"..."9").contains(f) { d = "0" + d }
        if d.count >= 2, let m = Int(d.prefix(2)), !(1...12).contains(m) { d = String(d.prefix(1)) }
        d = String(d.prefix(4))
        let deleting = new.count < old.count
        if d.count > 2 || (d.count == 2 && !deleting) { return String(d.prefix(2)) + "/" + String(d.dropFirst(2)) }
        if d.count == 1, d != "0", new.hasSuffix("/") { return "0\(d)/" }
        return d
    }

    /// "Dec 2034" for a complete expiry, and whether it has passed
    static func expiryNote(_ s: String) -> (label: String, expired: Bool)? {
        guard s.count == 5, let (m, y) = CardInfo.parse(s), var c = CardInfo(["brand": "Card"]) else { return nil }
        c.expiry = s
        let month = DateFormatter().shortMonthSymbols[m - 1]
        return ("\(month) \(y)", c.expired)
    }

    static func cvc(_ s: String, brand: String) -> String {
        String(digits(s).prefix(brand == "American Express" ? 4 : 3))
    }

    /// a name as printed on a card: letters, spaces and . ' -
    static func holder(_ s: String) -> String {
        var out = String(s.filter { $0.isLetter || $0 == " " || $0 == "." || $0 == "'" || $0 == "-" }.prefix(26))
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        if out.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    static func postal(_ s: String) -> String {
        String(s.uppercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == " " || $0 == "-" }.prefix(10))
    }
}
