import CoreBluetooth
import Observation

/// Monitors Bluetooth audio device connections.
/// A disconnect from a car audio device (CarPlay, A2DP) is a strong
/// signal that the user has just parked and left the vehicle.
@Observable
final class BluetoothManager: NSObject {
    var justDisconnectedFromCar: Bool = false

    private var centralManager: CBCentralManager!
    private var knownCarDeviceNames: Set<String> = []

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        loadKnownDevices()
    }

    // MARK: - Private

    private func loadKnownDevices() {
        // Persist car device names across sessions
        if let saved = UserDefaults.standard.stringArray(forKey: "altside_car_devices") {
            knownCarDeviceNames = Set(saved)
        }
    }

    private func saveKnownDevices() {
        UserDefaults.standard.set(Array(knownCarDeviceNames), forKey: "altside_car_devices")
    }

    private func isLikelyCar(_ name: String) -> Bool {
        let lower = name.lowercased()
        let carKeywords = ["car", "auto", "vehicle", "honda", "toyota", "ford", "bmw",
                           "chevy", "nissan", "hyundai", "kia", "audio", "stereo"]
        return carKeywords.contains { lower.contains($0) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // No action needed — we respond to connect/disconnect events
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let name = peripheral.name else { return }
        if isLikelyCar(name) {
            knownCarDeviceNames.insert(name)
            saveKnownDevices()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let name = peripheral.name else { return }
        if knownCarDeviceNames.contains(name) {
            justDisconnectedFromCar = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.justDisconnectedFromCar = false
            }
        }
    }
}
