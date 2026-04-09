import SwiftUI
import SwiftData

@main
struct AltSideApp: App {
    @State private var locationManager      = LocationManager()
    @State private var motionManager        = MotionManager()
    @State private var bluetoothManager     = BluetoothManager()
    @State private var cleaningData         = CleaningDataManager()
    @State private var notificationManager  = NotificationManager()
    @State private var liveActivityManager  = LiveActivityManager()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainMapView(
                    locationManager: locationManager,
                    motionManager: motionManager,
                    bluetoothManager: bluetoothManager,
                    cleaningDataManager: cleaningData,
                    notificationManager: notificationManager,
                    liveActivityManager: liveActivityManager
                )

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .fontDesign(.rounded)
            .preferredColorScheme(.light)
            .task { locationManager.startMonitoring() }
            .task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
            }
        }
        .modelContainer(for: [ParkingSpot.self, ReminderConfig.self])
    }
}
