import Foundation
import CoreLocation

/// DEBUG-only launch hook for the UI-test harness (FeedYuUITests): a
/// deterministic synthetic store + prefs + fixed location, so the
/// view-wiring contracts in docs/REQUIREMENTS.md are machine-checked
/// instead of hand-tested on a device. Activated by
/// `-uiTestSeed <scenario>`; release builds compile the body out.
///
/// Scenarios:
/// - `near`: three manual places within 2 km (plus one fake Michelin row)
///   — cold-launch and hide contracts.
/// - `far`:  one place ~3.3 km out with a 500 m budget — the
///   budget-change-with-no-card contract.
enum UITestSeed {
    #if DEBUG
    /// Matches the fixed fix LocationProvider publishes under the seed.
    static let origin = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)

    static var isActive: Bool {
        UserDefaults.standard.string(forKey: "uiTestSeed") != nil
    }

    /// Runs BEFORE the store loads (first line of bootstrap).
    static func applyIfRequested() {
        guard let scenario = UserDefaults.standard.string(forKey: "uiTestSeed") else { return }
        seedDefaults(scenario: scenario)
        seedStore(scenario: scenario)
    }

    /// Deterministic prefs. The Michelin filter keys are only cleared when
    /// `-uiTestResetFilters` is passed — the filter-persistence contract
    /// test relaunches WITHOUT it so the keys travel through the real
    /// persistence path (and every fresh test launch WITH it stays
    /// idempotent on a reused simulator).
    private static func seedDefaults(scenario: String) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasSeenOnboarding")
        defaults.set(true, forKey: "uberEatsURLsResetV2")
        // A fresh "weekly refresh" stamp plus a seeded guide row below keep
        // bootstrap from parsing (or downloading) the real Michelin CSVs.
        defaults.set(Date(), forKey: "michelinLastRemoteRefresh")
        // Distance mode = zero MapKit calls; assertions never wait on routes.
        let budget: [String: Any] = ["mode": "distance",
                                     "distanceMeters": scenario == "far" ? 500 : 2000,
                                     "walkMinutes": 15, "driveMinutes": 60]
        if let data = try? JSONSerialization.data(withJSONObject: budget) {
            defaults.set(data, forKey: "tonightBudget")
        }
        // Starve the Uber tab (nothing within 100 m): its auto-roll would
        // otherwise run real WebView checks against ubereats.com on every
        // test launch — slow, networked, and irrelevant to the assertions.
        defaults.set(100, forKey: "uberDistanceMeters")
        if defaults.string(forKey: "uiTestResetFilters") != nil {
            defaults.removeObject(forKey: "michelinPriceBands")
            defaults.removeObject(forKey: "michelinAwardFilters")
        }
    }

    private static func seedStore(scenario: String) {
        var places: [Restaurant]
        switch scenario {
        case "far":
            places = [place("Seed Gamma", latOffset: 0.03)]
        default: // "near"
            places = [place("Seed Alpha", latOffset: 0.003),
                      place("Seed Beta", latOffset: -0.003),
                      place("Seed Gamma", latOffset: 0.03)]
        }
        // One guide row: hasMichelin == true skips the bundled-CSV sync at
        // bootstrap (fast launches) and gives the Michelin tab one in-range
        // row. Empty lists + no manual flag = never a Tonight candidate.
        // NOT named "Seed …": the page-style TabView keeps every page in
        // the element tree, so a Michelin list row with that prefix would
        // satisfy the Tonight tests' card queries from offscreen.
        var star = Restaurant(name: "Guide Star Fixture")
        star.latitude = origin.latitude + 0.004
        star.longitude = origin.longitude
        star.michelinAward = .oneStar
        star.lastSeenInSourceAt = ["michelin": Date()]
        places.append(star)

        let snapshot = RestaurantStore.Snapshot(restaurants: places, syncStatuses: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: RestaurantStore.storeFileURL, options: .atomic)
        }
    }

    private static func place(_ name: String, latOffset: Double) -> Restaurant {
        var restaurant = Restaurant(name: name)
        restaurant.latitude = origin.latitude + latOffset
        restaurant.longitude = origin.longitude
        restaurant.addedManually = true
        restaurant.lastSeenInSourceAt = ["manual": Date()]
        return restaurant
    }
    #else
    static var isActive: Bool { false }
    static func applyIfRequested() {}
    #endif
}
