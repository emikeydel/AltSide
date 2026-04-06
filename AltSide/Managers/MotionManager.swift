import CoreMotion
import Observation

/// Detects when the user transitions from driving to stationary,
/// which triggers the "save your spot?" prompt.
@Observable
final class MotionManager {
    enum ActivityState {
        case unknown, driving, walking, stationary
    }

    var activityState: ActivityState = .unknown
    var justParked: Bool = false   // true for one cycle after driving→stationary

    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private var lastDrivingDate: Date?

    // MARK: - Public API

    func startMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.handle(activity: activity)
        }
    }

    func stopMonitoring() {
        activityManager.stopActivityUpdates()
    }

    // MARK: - Private

    private func handle(activity: CMMotionActivity) {
        let previous = activityState

        if activity.automotive {
            activityState = .driving
            lastDrivingDate = Date()
        } else if activity.walking || activity.running {
            activityState = .walking
        } else if activity.stationary {
            activityState = .stationary

            // Detect driving→stationary transition (parked)
            if previous == .driving,
               let lastDriving = lastDrivingDate,
               Date().timeIntervalSince(lastDriving) < 300 { // within 5 min
                justParked = true
                // Reset after one cycle so the UI can respond
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    self.justParked = false
                }
            }
        } else {
            activityState = .unknown
        }
    }
}
