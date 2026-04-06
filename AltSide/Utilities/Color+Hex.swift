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
    static let uberBlack    = Color(hex: "000000")
    static let uberSurface  = Color(hex: "1A1A1A")
    static let uberSurface2 = Color(hex: "242424")
    static let uberSurface3 = Color(hex: "2E2E2E")
    static let uberGreen    = Color(hex: "06C167")
    static let uberGreenDim = Color(hex: "06C167").opacity(0.15)
    static let uberAmber    = Color(hex: "F6961E")
    static let uberAmberDim = Color(hex: "F6961E").opacity(0.12)
    static let uberWhite    = Color.white
    static let uberGray1    = Color(hex: "EEEEEE")
    static let uberGray2    = Color(hex: "B2B2B2")
    static let uberGray3    = Color(hex: "6B6B6B")
    static let uberRed      = Color(hex: "E24B4A")
}
