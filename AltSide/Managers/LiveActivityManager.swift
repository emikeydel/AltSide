import ActivityKit
import Foundation
import Observation

@Observable
final class LiveActivityManager {

    private var activity: Activity<ParkingActivityAttributes>?

    var isActive: Bool { activity != nil }

    // MARK: - Start

    /// Only starts the Live Activity if cleaning is within 1 hour.
    /// Safe to call repeatedly — won't restart an already-running activity.
    func startIfNeeded(for spot: ParkingSpot) {
        guard !isActive,
              let cleaningDate = spot.nextCleaningDate,
              cleaningDate.timeIntervalSinceNow <= 3600 else { return }
        startActivity(for: spot)
    }

    private func startActivity(for spot: ParkingSpot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any existing activity first
        Task { await endActivity() }

        let attributes = ParkingActivityAttributes(spotID: spot.id.uuidString)
        let state = contentState(for: spot)
        let content = ActivityContent(
            state: state,
            staleDate: spot.nextCleaningDate
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {}
    }

    // MARK: - Update

    func updateActivity(for spot: ParkingSpot) async {
        let content = ActivityContent(
            state: contentState(for: spot),
            staleDate: spot.nextCleaningDate
        )
        await activity?.update(content)
    }

    // MARK: - End

    func endActivity() async {
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    // MARK: - Helpers

    private func contentState(for spot: ParkingSpot) -> ParkingActivityAttributes.ContentState {
        let cross: String
        if !spot.crossStreetFrom.isEmpty && !spot.crossStreetTo.isEmpty {
            cross = "between \(spot.crossStreetFrom) & \(spot.crossStreetTo)"
        } else {
            cross = ""
        }
        return ParkingActivityAttributes.ContentState(
            streetName: spot.streetName,
            sideDisplayName: spot.streetSide?.displayName ?? "",
            crossStreets: cross,
            moveByDisplay: spot.moveByDisplay,
            cleaningDate: spot.nextCleaningDate,
            isCleaningSoon: spot.isCleaningSoon
        )
    }
}
