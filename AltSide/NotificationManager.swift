import UserNotifications
import Foundation
import Observation

// Actions the app needs to perform in response to a notification tap.
enum ParkingNotificationAction: Equatable {
    case clearSpot(UUID)
    case navigateTo(UUID)
}

@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Set by the delegate when the user taps an action. Observed by MainMapView.
    var pendingAction: ParkingNotificationAction? = nil

    private let center = UNUserNotificationCenter.current()
    static let categoryIdentifier = "PARKING_ALERT"

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
        Task { await refreshStatus() }
    }

    // MARK: - Authorization

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshStatus()
            return granted
        } catch {
            return false
        }
    }

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    // MARK: - Schedule Alerts

    func scheduleAlerts(for spot: ParkingSpot) async {
        await cancelAlerts(for: spot.id)

        guard let cleaningDate = spot.nextCleaningDate else { return }

        let config = spot.reminderConfig
        var requests: [UNNotificationRequest] = []

        // 1. Before cleaning
        if config.beforeCleaningEnabled {
            let fireDate = cleaningDate.addingTimeInterval(-Double(config.beforeCleaningMinutes) * 60)
            if fireDate > Date() {
                let content = makeContent(
                    title: "Move your car — cleaning in \(config.beforeCleaningMinutes) min",
                    body: "\(spot.streetName) · \(spot.streetSide?.displayName ?? "") side · \(spot.moveByDisplay)",
                    spotID: spot.id
                )
                requests.append(makeRequest(id: "\(spot.id)_before", content: content, date: fireDate))
            }
        }

        // 2. Evening before
        if config.eveningBeforeEnabled {
            if let eve = eveningBefore(cleaningDate, hour: config.eveningBeforeHour, minute: config.eveningBeforeMinute) {
                let content = makeContent(
                    title: "Street cleaning tomorrow 🧹",
                    body: "\(spot.streetName) · \(spot.streetSide?.displayName ?? "") side · \(spot.moveByDisplay)",
                    spotID: spot.id
                )
                requests.append(makeRequest(id: "\(spot.id)_evening", content: content, date: eve))
            }
        }

        // 3. Morning of
        if config.morningOfEnabled {
            if let morning = morningOf(cleaningDate, hour: config.morningOfHour, minute: config.morningOfMinute) {
                let content = makeContent(
                    title: "Street cleaning today ⚠️",
                    body: "\(spot.streetName) · \(spot.streetSide?.displayName ?? "") side · \(spot.moveByDisplay)",
                    spotID: spot.id
                )
                requests.append(makeRequest(id: "\(spot.id)_morning", content: content, date: morning))
            }
        }

        for request in requests {
            try? await center.add(request)
        }
    }

    func cancelAlerts(for spotID: UUID) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix(spotID.uuidString) }.map { $0.identifier }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAllParkingAlerts() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map { $0.identifier }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banner + play sound even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle action button taps (from lock screen, notification centre, Dynamic Island, etc.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard
            let spotIDStr = response.notification.request.content.userInfo["spotID"] as? String,
            let spotID = UUID(uuidString: spotIDStr)
        else { return }

        switch response.actionIdentifier {

        case "MOVED_IT":
            // Cancel remaining alerts and signal the app to clear the spot.
            Task { await cancelAlerts(for: spotID) }
            pendingAction = .clearSpot(spotID)

        case "NAVIGATE":
            // Bring the app to foreground and open Maps navigation.
            pendingAction = .navigateTo(spotID)

        case "SNOOZE_15":
            Task { await snooze(response.notification.request) }

        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification body — just open the app (default behaviour).
            break

        default:
            break
        }
    }

    // MARK: - Snooze

    private func snooze(_ originalRequest: UNNotificationRequest) async {
        let snoozed = originalRequest.content.mutableCopy() as! UNMutableNotificationContent
        snoozed.title = "⏰ \(originalRequest.content.title)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        let request = UNNotificationRequest(
            identifier: originalRequest.identifier + "_snooze",
            content: snoozed,
            trigger: trigger
        )
        try? await center.add(request)
    }

    // MARK: - Private Helpers

    private func makeContent(title: String, body: String, spotID: UUID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["spotID": spotID.uuidString]
        return content
    }

    private func makeRequest(id: String, content: UNMutableNotificationContent, date: Date) -> UNNotificationRequest {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    private func eveningBefore(_ date: Date, hour: Int, minute: Int) -> Date? {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.day! -= 1
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard let fireDate = Calendar.current.date(from: comps) else { return nil }
        return fireDate > Date() ? fireDate : nil
    }

    private func morningOf(_ date: Date, hour: Int, minute: Int) -> Date? {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard let fireDate = Calendar.current.date(from: comps) else { return nil }
        return fireDate > Date() ? fireDate : nil
    }

    private func registerCategories() {
        let movedIt = UNNotificationAction(
            identifier: "MOVED_IT",
            title: "I moved it ✓",
            options: .destructive
        )
        let snooze = UNNotificationAction(
            identifier: "SNOOZE_15",
            title: "Snooze 15 min",
            options: []
        )
        let navigate = UNNotificationAction(
            identifier: "NAVIGATE",
            title: "Navigate to Car",
            options: .foreground
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [movedIt, snooze, navigate],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}
