import Foundation
import CoreLocation

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var location: CLLocation?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        #if DEBUG
        // UI-test harness: a fixed fix, granted auth, and NO delegate
        // wiring — CoreLocation (and its permission prompt) stays entirely
        // out of the test run.
        if UITestSeed.isActive {
            authorizationStatus = .authorizedWhenInUse
            location = CLLocation(latitude: UITestSeed.origin.latitude,
                                  longitude: UITestSeed.origin.longitude)
            return
        }
        #endif
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        #if os(iOS)
        return authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #else
        return authorizationStatus == .authorizedAlways
        #endif
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestPermissionIfNeeded() {
        #if DEBUG
        if UITestSeed.isActive { return } // fixed fix — nothing to request
        #endif
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            refresh()
        }
    }

    func refresh() {
        #if DEBUG
        if UITestSeed.isActive { return }
        #endif
        manager.requestLocation()
    }

    /// Foreground returns re-check location like they re-check Michelin data:
    /// a one-shot fix from launch goes stale if the app lives in the
    /// background while the user moves around. Gated on the fix's own
    /// timestamp so tab-switching in and out of the app doesn't spam
    /// CoreLocation.
    static let staleInterval: TimeInterval = 30 * 60

    func refreshIfStale() {
        #if DEBUG
        if UITestSeed.isActive { return }
        #endif
        guard isAuthorized else { return }
        let isStale = location.map {
            Date().timeIntervalSince($0.timestamp) > Self.staleInterval
        } ?? true
        if isStale {
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last {
            location = last
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known location; views show their own empty states.
    }
}
