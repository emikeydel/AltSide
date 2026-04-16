import Foundation
import SwiftData

@Model
class ReminderConfig {
    // Before street cleaning: fires X minutes before sweeper
    var beforeCleaningEnabled: Bool
    var beforeCleaningMinutes: Int // 15, 30, 60, or 90

    // Evening before: fires at a set time the night before
    var eveningBeforeEnabled: Bool
    var eveningBeforeHour: Int    // 0-23
    var eveningBeforeMinute: Int  // 0-59

    // Morning of cleaning day
    var morningOfEnabled: Bool
    var morningOfHour: Int
    var morningOfMinute: Int

    // When I get home from work (geofence on home address)
    var arrivedHomeEnabled: Bool
    var arrivedHomeDelayMinutes: Int // 0 = on arrival, 30 = 30 min after

    init(
        beforeCleaningEnabled: Bool = true,
        beforeCleaningMinutes: Int = 30,
        eveningBeforeEnabled: Bool = true,
        eveningBeforeHour: Int = 21,
        eveningBeforeMinute: Int = 0,
        morningOfEnabled: Bool = false,
        morningOfHour: Int = 7,
        morningOfMinute: Int = 0,
        arrivedHomeEnabled: Bool = false,
        arrivedHomeDelayMinutes: Int = 0
    ) {
        self.beforeCleaningEnabled = beforeCleaningEnabled
        self.beforeCleaningMinutes = beforeCleaningMinutes
        self.eveningBeforeEnabled = eveningBeforeEnabled
        self.eveningBeforeHour = eveningBeforeHour
        self.eveningBeforeMinute = eveningBeforeMinute
        self.morningOfEnabled = morningOfEnabled
        self.morningOfHour = morningOfHour
        self.morningOfMinute = morningOfMinute
        self.arrivedHomeEnabled = arrivedHomeEnabled
        self.arrivedHomeDelayMinutes = arrivedHomeDelayMinutes
    }

    var hasAnyEnabled: Bool {
        beforeCleaningEnabled || eveningBeforeEnabled || morningOfEnabled || arrivedHomeEnabled
    }
}
