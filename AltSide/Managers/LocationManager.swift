import CoreLocation
import Observation

@Observable
final class LocationManager: NSObject {
    // MARK: - Published State
    var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855) // Times Square default
    var heading: CLLocationDirection = 0
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var scoutModeActive: Bool = false {
        didSet { applyAccuracy() }
    }

    // MARK: - Private
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 5      // degrees of change to trigger update
        manager.headingOrientation = .portrait
        applyAccuracy()
    }

    // MARK: - Public API

    func startMonitoring() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        default:
            break
        }
    }

    func stopMonitoring() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    // MARK: - Private

    private func applyAccuracy() {
        manager.desiredAccuracy = scoutModeActive ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = scoutModeActive ? 5 : 20
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.coordinate = loc.coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.heading = h
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways ||
               manager.authorizationStatus == .authorizedWhenInUse {
                manager.startUpdatingLocation()
                manager.startUpdatingHeading()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal — will retry on next delegate call
    }
}
