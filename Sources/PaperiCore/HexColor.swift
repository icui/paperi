import Foundation

/// `#RRGGBB` or `#RRGGBBAA` (leading `#` optional) as 0...1 components.
public struct HexColor: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init?(_ text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let full = hex.count == 6 ? value << 8 | 0xFF : value
        red = Double(full >> 24 & 0xFF) / 255; green = Double(full >> 16 & 0xFF) / 255
        blue = Double(full >> 8 & 0xFF) / 255; alpha = Double(full & 0xFF) / 255
    }
}
