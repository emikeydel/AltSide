import SwiftUI

// MARK: - Environment keys for all shared managers

private struct LocationManagerKey: EnvironmentKey {
    static let defaultValue = LocationManager()
}
private struct MotionManagerKey: EnvironmentKey {
    static let defaultValue = MotionManager()
}
private struct BluetoothManagerKey: EnvironmentKey {
    static let defaultValue = BluetoothManager()
}
private struct CleaningDataManagerKey: EnvironmentKey {
    static let defaultValue = CleaningDataManager()
}
private struct NotificationManagerKey: EnvironmentKey {
    static let defaultValue = NotificationManager()
}
private struct LiveActivityManagerKey: EnvironmentKey {
    static let defaultValue = LiveActivityManager()
}

extension EnvironmentValues {
    var locationManager: LocationManager {
        get { self[LocationManagerKey.self] }
        set { self[LocationManagerKey.self] = newValue }
    }
    var motionManager: MotionManager {
        get { self[MotionManagerKey.self] }
        set { self[MotionManagerKey.self] = newValue }
    }
    var bluetoothManager: BluetoothManager {
        get { self[BluetoothManagerKey.self] }
        set { self[BluetoothManagerKey.self] = newValue }
    }
    var cleaningDataManager: CleaningDataManager {
        get { self[CleaningDataManagerKey.self] }
        set { self[CleaningDataManagerKey.self] = newValue }
    }
    var notificationManager: NotificationManager {
        get { self[NotificationManagerKey.self] }
        set { self[NotificationManagerKey.self] = newValue }
    }
    var liveActivityManager: LiveActivityManager {
        get { self[LiveActivityManagerKey.self] }
        set { self[LiveActivityManagerKey.self] = newValue }
    }
}
