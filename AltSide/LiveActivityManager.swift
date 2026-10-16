import ActivityKit
import Foundation
import Observation

@Observable
final class LiveActivityManager {

    private var activity: Activity<ParkingActivityAttributes>?

    /// Tracks which spot IDs have already received each alert so they only fire once.
    private var firedThirtyMinAlert: Set<String> = []
    private var firedTenMinAlert:    Set<String> = []

    var isActive: Bool { activity != nil }

    // MARK: - Start

    /// Starts the Live Activity (and Dynamic Island) when cleaning is within 30 minutes.
    /// Safe to call repeatedly — won't restart an already-running activity.
    func startIfNeeded(for spot: ParkingSpot) {
        guard !isActive,
              let cleaningDate = spot.nextCleaningDate,
              cleaningDate.timeIntervalSinceNow > 0,
              cleaningDate.timeIntervalSinceNow <= 1800 else { return }
        startActivity(for: spot)
    }

    private func startActivity(for spot: ParkingSpot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any existing activity first
        Task { await endActivity() }

        let attributes = ParkingActivityAttributes(spotID: spot.id.uuidString)
        let content = ActivityContent(
            state: contentState(for: spot),
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

    // MARK: - Urgent Alerts

    /// Call on a regular interval (e.g. every 5 min) while a spot is saved.
    /// Fires a Dynamic Island alert at ≤30 min and again at ≤10 min — once each.
    func checkUrgentAlerts(for spot: ParkingSpot) async {
        guard let cleaningDate = spot.nextCleaningDate else { return }
        let remaining = cleaningDate.timeIntervalSinceNow
        guard remaining > 0 else { return }

        let key = spot.id.uuidString

        if remaining <= 10 * 60, !firedTenMinAlert.contains(key) {
            firedTenMinAlert.insert(key)
            await sendAlert(
                for: spot,
                title: "Move your car now",
                body: "\(spot.streetName) — street cleaning starts in 10 minutes"
            )
        } else if remaining <= 30 * 60, !firedThirtyMinAlert.contains(key) {
            firedThirtyMinAlert.insert(key)
            await sendAlert(
                for: spot,
                title: "Move your car soon",
                body: "\(spot.streetName) — street cleaning in 30 minutes"
            )
        }
    }

    private func sendAlert(for spot: ParkingSpot, title: String, body: String) async {
        // Start the activity if it isn't running yet (in case startIfNeeded hasn't fired this cycle)
        if !isActive { startActivity(for: spot) }
        let content = ActivityContent(
            state: contentState(for: spot),
            staleDate: spot.nextCleaningDate
        )
        let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: title),
                                       body: LocalizedStringResource(stringLiteral: body),
                                       sound: .default)
        await activity?.update(content, alertConfiguration: alert)
    }

    // MARK: - End

    func endActivity() async {
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    /// Call when the saved spot is cleared so alert state resets for the next session.
    func resetAlertState(for spotID: String) {
        firedThirtyMinAlert.remove(spotID)
        firedTenMinAlert.remove(spotID)
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
