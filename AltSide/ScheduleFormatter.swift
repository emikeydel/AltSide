import Foundation

enum ScheduleFormatter {
    static let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func time(_ h: Int, _ m: Int) -> String {
        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        let period = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(h12) \(period)" : "\(h12):\(String(format: "%02d", m)) \(period)"
    }
}
