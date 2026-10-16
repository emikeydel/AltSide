import UIKit
import SwiftData

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    let sharedModelContainer: ModelContainer = {
        try! ModelContainer(for: ParkingSpot.self, ReminderConfig.self)
    }()

    let locationManager     = LocationManager()
    let motionManager       = MotionManager()
    let bluetoothManager    = BluetoothManager()
    let cleaningData        = CleaningDataManager()
    let notificationManager = NotificationManager()
    let liveActivityManager = LiveActivityManager()
    let aspStatus           = ASPStatusManager()
    let permits             = StreetPermitManager()

    // Created here so it exists before any CarPlay scene connects.
    private(set) var carPlayCoordinator: CarPlayCoordinator?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        locationManager.startMonitoring()
        // Live 311 ASP status (emergency suspensions, next year's holidays) before any UI/CarPlay.
        Task { await aspStatus.refresh() }
        carPlayCoordinator = CarPlayCoordinator(
            locationManager: locationManager,
            cleaningDataManager: cleaningData,
            notificationManager: notificationManager,
            modelContainer: sharedModelContainer
        )
        return true
    }
}
