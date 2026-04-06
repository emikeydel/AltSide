import Foundation
import SwiftData
import CoreLocation

@Model
class ParkingSpot {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var streetName: String
    var crossStreetFrom: String
    var crossStreetTo: String
    var side: String               // "north" | "south" | "east" | "west"
    var savedAt: Date
    var cleaningDays: [Int]        // weekday integers, 1=Sunday
    var cleaningStartHour: Int
    var cleaningStartMinute: Int
    var cleaningEndHour: Int
    var cleaningEndMinute: Int
    var nextCleaningDate: Date?
    var reminderConfig: ReminderConfig
    var isActive: Bool

    init(
        id: UUID = UUID(),
        coordinate: CLLocationCoordinate2D,
        streetName: String,
        crossStreetFrom: String = "",
        crossStreetTo: String = "",
        side: SideDetector.StreetSide,
        cleaningDays: [Int] = [],
        cleaningStartHour: Int = 8,
        cleaningStartMinute: Int = 0,
        cleaningEndHour: Int = 9,
        cleaningEndMinute: Int = 30,
        nextCleaningDate: Date? = nil,
        reminderConfig: ReminderConfig = ReminderConfig()
    ) {
        self.id = id
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.streetName = streetName
        self.crossStreetFrom = crossStreetFrom
        self.crossStreetTo = crossStreetTo
        self.side = side.rawValue
        self.savedAt = Date()
        self.cleaningDays = cleaningDays
        self.cleaningStartHour = cleaningStartHour
        self.cleaningStartMinute = cleaningStartMinute
        self.cleaningEndHour = cleaningEndHour
        self.cleaningEndMinute = cleaningEndMinute
        self.nextCleaningDate = nextCleaningDate
        self.reminderConfig = reminderConfig
        self.isActive = true
    }

    // MARK: - Computed

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var streetSide: SideDetector.StreetSide? {
        SideDetector.StreetSide(rawValue: side)
    }

    var displayAddress: String {
        if crossStreetFrom.isEmpty && crossStreetTo.isEmpty {
            return streetName
        }
        return "\(streetName)\nbetween \(crossStreetFrom) & \(crossStreetTo)"
    }

    var moveByDisplay: String {
        // subtract 1 minute for "move by" display
        let adjustedMinute = cleaningStartMinute == 0 ? 59 : cleaningStartMinute - 1
        let adjustedHour = cleaningStartMinute == 0 ? max(0, cleaningStartHour - 1) : cleaningStartHour
        let ah = adjustedHour == 0 ? 12 : (adjustedHour > 12 ? adjustedHour - 12 : adjustedHour)
        let am = adjustedMinute == 0 ? "" : ":\(String(format: "%02d", adjustedMinute))"
        let ap = adjustedHour < 12 ? "AM" : "PM"
        return "Move by \(ah)\(am) \(ap)"
    }

    var timeUntilCleaning: TimeInterval? {
        guard let next = nextCleaningDate else { return nil }
        let interval = next.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }

    var isCleaningSoon: Bool {
        guard let t = timeUntilCleaning else { return false }
        return t < 48 * 3600
    }

    /// Recalculates nextCleaningDate from cleaningDays. Call after saving.
    func refreshNextCleaningDate() {
        let cal = Calendar.current
        let now = Date()
        var earliest: Date?
        for weekdayInt in cleaningDays {
            for daysAhead in 0...6 {
                guard let candidate = cal.date(byAdding: .day, value: daysAhead, to: now) else { continue }
                guard cal.component(.weekday, from: candidate) == weekdayInt else { continue }
                var comps = cal.dateComponents([.year, .month, .day], from: candidate)
                comps.hour = cleaningStartHour; comps.minute = cleaningStartMinute; comps.second = 0
                guard let start = cal.date(from: comps) else { continue }
                if daysAhead == 0 {
                    comps.hour = cleaningEndHour; comps.minute = cleaningEndMinute
                    guard let end = cal.date(from: comps), now < end else { continue }
                }
                if earliest == nil || start < earliest! { earliest = start }
                break
            }
        }
        nextCleaningDate = earliest
    }
}
