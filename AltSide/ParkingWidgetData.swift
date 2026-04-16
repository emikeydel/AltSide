import Foundation

/// Shared data model written by the main app and read by the widget extension.
/// Stored in the shared App Group UserDefaults.
struct ParkingWidgetData: Codable {
    var streetName: String
    var sideDisplayName: String
    var moveByDisplay: String
    var scheduleDisplay: String   // e.g. "Mon 8:30 AM – 10 AM"
    var cleaningDate: Date?
    var isCleaningSoon: Bool
    var isParked: Bool

    // ── App Group ──────────────────────────────────────────────────────────
    // Must match the App Group identifier you enable in Signing & Capabilities
    // for BOTH the Sweepy and Sweepy Widget targets.
    static let appGroupID = "group.com.laidoffdad.sweepy"
    static let key        = "parkingWidgetData"

    // MARK: - Persistence

    static func load() -> ParkingWidgetData? {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data     = defaults.data(forKey: key),
            let decoded  = try? JSONDecoder().decode(ParkingWidgetData.self, from: data)
        else { return nil }
        return decoded
    }

    func save() {
        guard
            let defaults = UserDefaults(suiteName: Self.appGroupID),
            let encoded  = try? JSONEncoder().encode(self)
        else { return }
        defaults.set(encoded, forKey: Self.key)
    }

    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: key)
    }
}
