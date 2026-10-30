import SwiftUI

/// What an entry is. Logins fill login forms; the others each have their own way in: cards fill checkouts,
/// keys go to scripts, notes stay put, values come back in commands' blanks, the Mac password only goes to sudo.
enum Kind: String, CaseIterable, Identifiable {
    case login, card, key, note, value, mac

    var id: String { rawValue }

    init(_ raw: String?) { self = Kind(rawValue: raw ?? "") ?? .login }

    var title: String {
        switch self {
        case .login: "Login"
        case .card: "Card"
        case .key: "Key"
        case .note: "Secure Note"
        case .value: "Value"
        case .mac: "Mac Password"
        }
    }

    /// as a word in a sentence ("New key")
    var inSentence: String {
        switch self {
        case .mac: "Mac password"
        default: title.lowercased()
        }
    }

    var symbol: String {
        switch self {
        case .login: "person.crop.circle"
        case .card: "creditcard"
        case .key: "key.horizontal"
        case .note: "note.text"
        case .value: "character.cursor.ibeam"
        case .mac: "lock.laptopcomputer"
        }
    }

    /// Paying, running things as root, and what goes into a command: an earlier Touch ID yes doesn't cover
    /// the next use, a new one starts at Touch ID, and scripts don't get it.
    var eachUse: Bool { self == .card || self == .mac || self == .value }

    /// Every card fill and every command asks, so those don't offer Auto. The Mac password can be Auto,
    /// after Touch ID.
    var offersAuto: Bool { self != .card && self != .value }

    /// what a new one starts with
    var policy: String { eachUse ? "ask" : "auto" }

    /// what `otto run --env VAR=entry` hands over without a field
    var mainField: String {
        switch self {
        case .card: "number"
        case .key: "key"
        case .note: "notes"
        case .value: "value"
        case .login, .mac: "password"
        }
    }

    /// the line under a new entry's name
    var newLine: String {
        switch self {
        case .login: "new login"
        case .card: "agents fill it at checkouts, after your Touch ID"
        case .key: "agents hand it to programs with otto run"
        case .note: "new secure note"
        case .value: "for commands: it comes back when one asks for it, and agents never see it"
        case .mac: "this Mac's password, only for sudo after your Touch ID"
        }
    }
}

/// What can be shown about a card without its secrets (the service's CardInfo).
struct CardInfo: Hashable {
    var brand: String
    var last4: String
    /// MM/YY
    var expiry: String?

    init?(_ j: [String: Any]?) {
        guard let j else { return nil }
        brand = j["brand"] as? String ?? "Card"
        last4 = j["last4"] as? String ?? ""
        expiry = j["expiry"] as? String
    }

    var label: String { last4.isEmpty ? brand : "\(brand) •••• \(last4)" }

    /// past its expiry month
    var expired: Bool {
        guard let e = expiry, let (m, y) = Self.parse(e) else { return false }
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return (y, m) < (now.year ?? 0, now.month ?? 0)
    }

    static func parse(_ s: String) -> (Int, Int)? {
        let parts = s.split(whereSeparator: { !$0.isNumber }).map(String.init)
        let (m, y): (Int?, Int?) = parts.count == 2 ? (Int(parts[0]), Int(parts[1]))
            : parts.count == 1 && [4, 6].contains(parts[0].count) ? (Int(parts[0].prefix(2)), Int(parts[0].dropFirst(2))) : (nil, nil)
        guard let m, let y, (1...12).contains(m) else { return nil }
        return (m, y < 100 ? 2000 + y : y)
    }

    /// the brand from the number's first digits, while typing one (the service decides for real)
    static func brand(of number: String) -> String {
        let d = number.filter(\.isNumber)
        let p = { (n: Int) in Int(d.prefix(n)) ?? 0 }
        if d.hasPrefix("4") { return "Visa" }
        if (51...55).contains(p(2)) || (2221...2720).contains(p(4)) { return "Mastercard" }
        if p(2) == 34 || p(2) == 37 { return "American Express" }
        if d.hasPrefix("9792") { return "Troy" }
        if d.hasPrefix("6011") || d.hasPrefix("65") || (644...649).contains(p(3)) { return "Discover" }
        if (3528...3589).contains(p(4)) { return "JCB" }
        if d.hasPrefix("62") { return "UnionPay" }
        if (300...305).contains(p(3)) || p(2) == 36 || p(2) == 38 { return "Diners Club" }
        return "Card"
    }

    /// the check digit every card number ends with
    static func luhn(_ number: String) -> Bool {
        let d = number.compactMap(\.wholeNumberValue)
        guard (12...19).contains(d.count), d.count == number.filter({ !$0.isWhitespace && $0 != "-" }).count else { return false }
        let sum = d.reversed().enumerated().reduce(0) { s, x in
            let w = x.offset % 2 == 1 ? x.element * 2 : x.element
            return s + (w > 9 ? w - 9 : w)
        }
        return sum % 10 == 0
    }

    /// "4242424242424242" -> "4242 4242 4242 4242" (Amex: 4-6-5, 14-digit Diners: 4-6-4)
    static func grouped(_ number: String) -> String {
        let d = Array(number.filter(\.isNumber))
        let sizes = d.count == 15 ? [4, 6, 5] : d.count == 14 ? [4, 6, 4] : Array(repeating: 4, count: (d.count + 3) / 4)
        var out: [String] = []
        var i = 0
        for n in sizes where i < d.count {
            out.append(String(d[i..<min(i + n, d.count)]))
            i += n
        }
        return out.joined(separator: " ")
    }
}

/// A kind's symbol on a quiet tile, for entries without a site or app of their own.
struct KindGlyph: View {
    let kind: Kind
    var size: CGFloat = 28
    /// a value kept out of sight
    var secret = false

    var body: some View {
        Image(systemName: secret ? "ellipsis.rectangle" : kind.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
    }
}

/// An entry's icon: its card, its site's or app's icon, or its kind.
struct EntryIcon: View {
    let kind: Kind
    var card: CardInfo?
    let site: String?
    var app: String?
    let name: String
    var size: CGFloat = 28
    /// a value kept out of sight
    var secret = false

    var body: some View {
        switch kind {
        case .card:
            CardBadge(brand: card?.brand ?? "Card", size: size)
        case .note, .mac, .value:
            KindGlyph(kind: kind, size: size, secret: secret)
        case .key where (site ?? "").isEmpty && (app ?? "").isEmpty:
            KindGlyph(kind: kind, size: size)
        default:
            SiteIcon(site: site, app: app, name: name, size: size)
        }
    }

    /// the color an entry's detail washes in
    static func tint(kind: Kind, card: CardInfo?, site: String?, app: String?) -> Color {
        switch kind {
        case .card: CardArt.tint(card?.brand ?? "Card")
        case .note, .mac: Icons.neutral
        case .value: Shelf.remembered.tint
        default: Icons.shared.tint(site: site, app: app)
        }
    }
}

extension Entry {
    var kindValue: Kind { Kind(kind) }
}

/// The vault as the sidebar groups it: a tile for each, and a section for each.
enum Shelf: String, CaseIterable, Identifiable {
    case logins, codes, cards, keys, notes, remembered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logins: "Logins"
        case .codes: "2FA Codes"
        case .cards: "Cards"
        case .keys: "Keys"
        case .notes: "Notes"
        case .remembered: "Remembered"
        }
    }

    var symbol: String {
        switch self {
        case .logins: Kind.login.symbol
        case .codes: "number"
        case .cards: Kind.card.symbol
        case .keys: Kind.key.symbol
        case .notes: Kind.note.symbol
        case .remembered: Kind.value.symbol
        }
    }

    var tint: Color {
        switch self {
        case .logins: .blue
        case .codes: .green
        case .cards: .orange
        case .keys: .purple
        case .notes: .yellow
        case .remembered: .teal
        }
    }

    /// what's in it. Every 2FA code counts, also the ones on a login
    func holds(_ e: Entry) -> Bool {
        switch self {
        case .logins: !e.library && e.kindValue == .login
        case .codes: e.totp != nil
        case .cards: e.kindValue == .card
        case .keys: e.kindValue == .key || e.kindValue == .mac
        case .notes: e.kindValue == .note
        case .remembered: e.kindValue == .value
        }
    }

    /// what New adds here; 2FA codes get imported or added to a login
    var newKind: Kind? {
        switch self {
        case .logins: .login
        case .codes: nil
        case .cards: .card
        case .keys: .key
        case .notes: .note
        case .remembered: .value
        }
    }

    /// "no keys yet"
    var empty: String {
        switch self {
        case .codes: "no 2FA codes yet"
        case .remembered: "nothing remembered yet"
        default: "no \(title.lowercased()) yet"
        }
    }
}
