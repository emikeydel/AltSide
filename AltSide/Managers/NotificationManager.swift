import UserNotifications
import Foundation
import Observation

@Observable
final class NotificationManager {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    static let categoryIdentifier = "PARKING_ALERT"

    init() {
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
                    body: "\(spot.streetName) · \(spot.streetSide?.displayName ?? "") side · \(spot.moveByDisplay)"
                )
                requests.append(makeRequest(id: "\(spot.id)_before", content: content, date: fireDate))
            }
        }

        // 2. Evening before
        if config.eveningBeforeEnabled {
            if let eve = eveningBefore(cleaningDate, hour: config.eveningBeforeHour, minute: config.eveningBeforeMinute) {
                let content = makeContent(
                    title: "Street cleaning tomorrow 🧹",
                    body: "\(spot.streetName) · \(spot.streetSide?.displayName ?? "") side · \(spot.moveByDisplay)"
                )
                requests.append(makeRequest(id: "\(spot.id)_evening", content: content, date: eve))
            }
        }

        // 3. Morning of
        if config.morningOfEnabled {
            if let morning = morningOf(cleaningDate, hour: config.morningOfHour, minute: config.morningOfMinute) {
                let content = makeContent(
                    title: "Street cleaning today ⚠️",
                    body: "\(spot.streetName) · \(spot.streetSide?.displayName ?? "") side · \(spot.moveByDisplay)"
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

    // MARK: - Private Helpers

    private func makeContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
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
        let navigate = UNNotificationAction(
            identifier: "NAVIGATE",
            title: "Navigate to Car",
            options: .foreground
        )
        let moved = UNNotificationAction(
            identifier: "ALREADY_MOVED",
            title: "Already Moved",
            options: .destructive
        )
        let snooze = UNNotificationAction(
            identifier: "SNOOZE_30",
            title: "Snooze 30 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [navigate, moved, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}
