import Foundation

/// One cleaning rule for a specific street block-face and weekday.
/// Created by expanding a raw NYC DOT sign record via `SignDescriptionParser`.
/// Stored in the per-street disk cache and used throughout the app for schedule queries.
struct StreetCleaningEntry: Codable, Identifiable {
    let id: UUID

    let streetName: String      // Normalized: "WEST 79 STREET"
    let fromStreet: String      // Cross street start of block
    let toStreet: String        // Cross street end of block
    let sideOfStreet: String    // "N", "S", "E", or "W"
    let weekDay: String         // "Monday", "Tuesday", …, "Saturday"
    let fromHour: Int           // 24-hour start hour
    let fromMinutes: Int
    let toHour: Int
    let toMinutes: Int
    let borough: String         // "Manhattan", "Brooklyn", etc.
    let signXCoord: Double?     // NY State Plane (EPSG:2263) X, US survey feet
    let signYCoord: Double?     // NY State Plane (EPSG:2263) Y, US survey feet
    let signLatitude: Double?   // WGS84 latitude of sign (from API)
    let signLongitude: Double?  // WGS84 longitude of sign (from API)

    // All stored entries are active — we only cache current signs.
    var isActive: Bool { true }

    // MARK: - Derived

    var normalizedSide: SideDetector.StreetSide? {
        switch sideOfStreet.uppercased() {
        case "N", "NORTH": return .north
        case "S", "SOUTH": return .south
        case "E", "EAST":  return .east
        case "W", "WEST":  return .west
        default:           return nil
        }
    }

    /// Weekday as Calendar.weekday integer (1 = Sunday, 2 = Monday, …).
    var weekdayInt: Int? {
        switch weekDay.prefix(3).lowercased() {
        case "sun": return 1
        case "mon": return 2
        case "tue": return 3
        case "wed": return 4
        case "thu": return 5
        case "fri": return 6
        case "sat": return 7
        default:    return nil
        }
    }

    var startHour: Int   { fromHour }
    var startMinute: Int { fromMinutes }
    var endHour: Int     { toHour }
    var endMinute: Int   { toMinutes }

    /// Human-readable time window e.g. "8:00 – 9:30 AM"
    var timeWindowDisplay: String {
        let startStr = formatTime(h: fromHour, m: fromMinutes)
        let endStr   = formatTime(h: toHour,   m: toMinutes)
        let period   = toHour < 12 ? "AM" : "PM"
        return "\(startStr) – \(endStr) \(period)"
    }

    private func formatTime(h: Int, m: Int) -> String {
        let hour = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return m == 0 ? "\(hour)" : "\(hour):\(String(format: "%02d", m))"
    }

    /// Next Date this cleaning occurs, starting from `from`.
    func nextCleaningDate(from date: Date = Date()) -> Date? {
        guard let targetWeekday = weekdayInt else { return nil }
        let cal = Calendar.current
        for daysAhead in 0...7 {
            guard let candidate = cal.date(byAdding: .day, value: daysAhead, to: date) else { continue }
            guard cal.component(.weekday, from: candidate) == targetWeekday else { continue }

            var comps = cal.dateComponents([.year, .month, .day], from: candidate)
            comps.hour = fromHour; comps.minute = fromMinutes; comps.second = 0
            guard let start = cal.date(from: comps) else { continue }

            if daysAhead == 0 {
                comps.hour = toHour; comps.minute = toMinutes
                guard let end = cal.date(from: comps), date < end else { continue }
            }
            return start
        }
        return nil
    }

    func isActiveRightNow(date: Date = Date()) -> Bool {
        guard let targetWeekday = weekdayInt else { return false }
        let cal = Calendar.current
        guard cal.component(.weekday, from: date) == targetWeekday else { return false }
        let currentMinutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return currentMinutes >= fromHour * 60 + fromMinutes
            && currentMinutes <  toHour   * 60 + toMinutes
    }
}
