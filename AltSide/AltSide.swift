import SwiftUI
import SwiftData

@main
struct AltSideApp: App {
    // Shared container used by both SwiftUI @Query and CarPlayCoordinator.
    // Creating it once ensures both read/write to the same SQLite store.
    private let sharedModelContainer: ModelContainer = {
        try! ModelContainer(for: ParkingSpot.self, ReminderConfig.self)
    }()

    @State private var locationManager      = LocationManager()
    @State private var motionManager        = MotionManager()
    @State private var bluetoothManager     = BluetoothManager()
    @State private var cleaningData         = CleaningDataManager()
    @State private var notificationManager  = NotificationManager()
    @State private var liveActivityManager  = LiveActivityManager()
    @State private var showSplash = true
    @State private var carPlayCoordinator: CarPlayCoordinator?

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
                if carPlayCoordinator == nil {
                    carPlayCoordinator = CarPlayCoordinator(
                        locationManager: locationManager,
                        cleaningDataManager: cleaningData,
                        notificationManager: notificationManager,
                        modelContainer: sharedModelContainer
                    )
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
