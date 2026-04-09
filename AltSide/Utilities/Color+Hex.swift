import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 6:
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Design System Tokens

extension Color {
    static let uberBlack    = Color(hex: "EAE8E0")          // warm cream — app background
    static let uberSurface  = Color.white                    // card / panel background
    static let uberSurface2 = Color(hex: "F5F2EC")          // secondary surface
    static let uberSurface3 = Color(hex: "E8E4DC")          // chip / tertiary surface
    static let uberGreen    = Color(hex: "2DB349")           // primary green
    static let uberGreenDim = Color(hex: "2DB349").opacity(0.15)
    static let uberAmber    = Color(hex: "FF5E00")           // warning orange
    static let uberAmberDim = Color(hex: "FF5E00").opacity(0.15)
    static let uberWhite    = Color(hex: "1A1A1A")           // primary text (dark on light bg)
    static let uberGray1    = Color(hex: "333333")           // secondary dark text
    static let uberGray2    = Color(hex: "555555")           // medium text
    static let uberGray3    = Color(hex: "888888")           // muted / caption
    static let uberRed      = Color(hex: "E24B4A")           // error / car pin
    static let uberBorder   = Color.black.opacity(0.08)      // card border on light bg
}
