import SwiftUI
import SwiftData

@main
struct AltSideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainMapView()
                    .environment(\.locationManager, appDelegate.locationManager)
                    .environment(\.motionManager, appDelegate.motionManager)
                    .environment(\.bluetoothManager, appDelegate.bluetoothManager)
                    .environment(\.cleaningDataManager, appDelegate.cleaningData)
                    .environment(\.notificationManager, appDelegate.notificationManager)
                    .environment(\.liveActivityManager, appDelegate.liveActivityManager)
                    .environment(\.aspStatus, appDelegate.aspStatus)
                    .environment(\.permits, appDelegate.permits)

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .fontDesign(.rounded)
            .preferredColorScheme(.dark)
            .task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
            }
        }
        .modelContainer(appDelegate.sharedModelContainer)
    }
}
