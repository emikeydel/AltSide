import ActivityKit
import Foundation

/// Shared between the main app and the Widget Extension.
/// Static data goes here; dynamic data goes in ContentState.
struct ParkingActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        var streetName: String
        var sideDisplayName: String
        var crossStreets: String        // "between X & Y", empty if unknown
        var moveByDisplay: String       // "Move by Thu 11:29 AM"
        var cleaningDate: Date?         // drives the live countdown timer
        var isCleaningSoon: Bool
    }

    var spotID: String
}
