import Foundation

// MARK: - State

enum CarPlayState {
    case noSpot
    case scouting(
        streetName: String,
        leftLabel: String,  leftSchedule: String,
        rightLabel: String, rightSchedule: String
    )
    case spotSaved(
        streetName: String,
        sideLabel: String,
        schedule: String,
        nextCleaning: String,
        spotID: UUID
    )
}

// MARK: - Store

/// Bridge between the main app and the CarPlay scene.
/// The coordinator writes to this; the scene delegate reads from it.
final class CarPlayDataStore {
    static let shared = CarPlayDataStore()
    private init() {}

    var state: CarPlayState = .noSpot
    var aspSummary: String = ""

    // Callbacks — set by the coordinator, invoked by the scene delegate on user action.
    var onFindParkingTapped: (() -> Void)?
    var onSaveLeftTapped: (() -> Void)?
    var onSaveRightTapped: (() -> Void)?
    var onParkAgainConfirmed: (() -> Void)?
    var onSetRemindersConfirmed: (() -> Void)?

    /// Called on the main queue whenever the state changes.
    var onUpdate: (() -> Void)?

    func setState(_ newState: CarPlayState, aspSummary: String) {
        state = newState
        self.aspSummary = aspSummary
        onUpdate?()
    }
}
