import SwiftUI
import SwiftData

@main
struct AltSideApp: App {
    @State private var locationManager  = LocationManager()
    @State private var motionManager    = MotionManager()
    @State private var bluetoothManager = BluetoothManager()
    @State private var cleaningData     = CleaningDataManager()
    @State private var notificationManager = NotificationManager()

    var body: some Scene {
        WindowGroup {
            MainMapView(
                locationManager: locationManager,
                motionManager: motionManager,
                bluetoothManager: bluetoothManager,
                cleaningDataManager: cleaningData,
                notificationManager: notificationManager
            )
            .preferredColorScheme(.dark)
            .task { locationManager.startMonitoring() }
            .task { motionManager.startMonitoring() }
            .task { _ = await notificationManager.requestPermission() }
        }
        .modelContainer(for: [ParkingSpot.self, ReminderConfig.self])
    }
}
