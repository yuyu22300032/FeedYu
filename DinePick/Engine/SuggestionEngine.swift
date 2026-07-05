import Foundation
import CoreLocation
import MapKit

struct Suggestion: Identifiable, Equatable {
    var restaurant: Restaurant
    var etaMinutes: Int?
    var straightLineKm: Double
    var id: UUID { restaurant.id }
}

/// Shuffled no-repeat suggestion queue with lazy, cached, traffic-aware ETA
/// checks. One instance per tab (each tab has its own no-repeat session).
@MainActor
final class SuggestionEngine: ObservableObject {
    @Published private(set) var current: Suggestion?
    @Published private(set) var isSearching = false
    @Published private(set) var statusMessage: String?

    /// Injectable for tests. Default uses MKDirections.calculateETA with
    /// departure = now, which is traffic-aware and needs no API key.
    var etaProvider: (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> TimeInterval = SuggestionEngine.mapKitETA

    /// MapKit throttles directions requests — bound the work per refresh.
    var maxETAChecksPerRefresh = 12

    private var queue: [Restaurant] = []
    private var shownIDs: Set<UUID> = []
    private var sessionOrigin: CLLocation?
    private var sessionBudget = 0
    private var sessionCandidateIDs: Set<UUID> = []

    private struct CachedETA {
        let seconds: TimeInterval
        let date: Date
    }
    private var etaCache: [String: CachedETA] = [:]
    private let etaCacheTTL: TimeInterval = 600

    func reset() {
        current = nil
        statusMessage = nil
        sessionOrigin = nil
        queue = []
        shownIDs = []
    }

    /// Pops the next candidate within the drive-time budget (current traffic).
    /// No repeats until the in-range pool is exhausted, then reshuffles.
    func refreshSuggestion(candidates: [Restaurant], origin: CLLocation, budgetMinutes: Int) async {
        guard !isSearching else { return }
        isSearching = true
        statusMessage = nil
        defer { isSearching = false }

        ensureSession(candidates: candidates, origin: origin, budgetMinutes: budgetMinutes)

        let pool = prefilter(candidates, origin: origin, budgetMinutes: budgetMinutes)
        if pool.isEmpty {
            current = nil
            statusMessage = String(localized: "No restaurants within roughly \(budgetMinutes) min of you. Try a bigger budget or add more places.")
            return
        }

        if queue.isEmpty {
            // Exhausted: reshuffle the whole pool, avoiding an immediate repeat.
            shownIDs = []
            rebuildQueue(from: pool)
            if let currentID = current?.id, queue.count > 1,
               let index = queue.firstIndex(where: { $0.id == currentID }) {
                let repeated = queue.remove(at: index)
                queue.append(repeated)
            }
            if current != nil {
                statusMessage = String(localized: "Seen everything in range — starting the rotation over.")
            }
        }

        var checks = 0
        while !queue.isEmpty && checks < maxETAChecksPerRefresh {
            let candidate = queue.removeFirst()
            guard let coordinate = candidate.coordinate else { continue }
            checks += 1
            do {
                let eta = try await cachedETA(id: candidate.id, from: origin, to: coordinate)
                if eta <= Double(budgetMinutes) * 60 {
                    shownIDs.insert(candidate.id)
                    let km = (candidate.distance(from: origin) ?? 0) / 1000
                    current = Suggestion(restaurant: candidate,
                                         etaMinutes: Int((eta / 60).rounded()),
                                         straightLineKm: km)
                    return
                }
                // Outside the budget in current traffic — drop it for this session.
            } catch let error as MKError where error.code == .loadingThrottled {
                queue.insert(candidate, at: 0)
                statusMessage = String(localized: "Apple Maps is rate-limiting drive-time checks. Wait a minute and refresh.")
                return
            } catch {
                statusMessage = String(localized: "Couldn't check drive time for some places (network?).")
            }
        }
        if queue.isEmpty && shownIDs.isEmpty {
            current = nil
            statusMessage = String(localized: "Nothing reachable within \(budgetMinutes) min in current traffic.")
        } else if statusMessage == nil {
            statusMessage = String(localized: "Nothing new within \(budgetMinutes) min so far — refresh to keep looking.")
        }
    }

    // MARK: - Session

    private func ensureSession(candidates: [Restaurant], origin: CLLocation, budgetMinutes: Int) {
        let ids = Set(candidates.map(\.id))
        if let sessionOrigin,
           sessionOrigin.distance(from: origin) < 2000,
           sessionBudget == budgetMinutes,
           sessionCandidateIDs == ids {
            return
        }
        self.sessionOrigin = origin
        sessionBudget = budgetMinutes
        sessionCandidateIDs = ids
        shownIDs = []
        rebuildQueue(from: prefilter(candidates, origin: origin, budgetMinutes: budgetMinutes))
    }

    /// Straight-line pre-filter: radius ≈ budget × 1.3 km/min. Generous, just
    /// avoids ETA calls for hopeless candidates.
    private func prefilter(_ candidates: [Restaurant], origin: CLLocation, budgetMinutes: Int) -> [Restaurant] {
        let radiusMeters = Double(budgetMinutes) * 1.3 * 1000
        return candidates.filter { candidate in
            guard let distance = candidate.distance(from: origin) else { return false }
            return distance <= radiusMeters
        }
    }

    private func rebuildQueue(from pool: [Restaurant]) {
        queue = pool.filter { !shownIDs.contains($0.id) }.shuffled()
    }

    // MARK: - ETA

    private func cachedETA(id: UUID, from origin: CLLocation, to destination: CLLocationCoordinate2D) async throws -> TimeInterval {
        // Origin bucketed to a ~500 m grid so tiny GPS jitter reuses the cache.
        let key = "\(id.uuidString)|\(Int(origin.coordinate.latitude * 200))|\(Int(origin.coordinate.longitude * 200))"
        if let cached = etaCache[key], Date().timeIntervalSince(cached.date) < etaCacheTTL {
            return cached.seconds
        }
        let eta = try await etaProvider(origin.coordinate, destination)
        etaCache[key] = CachedETA(seconds: eta, date: Date())
        return eta
    }

    static func mapKitETA(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.departureDate = Date()
        let response = try await MKDirections(request: request).calculateETA()
        return response.expectedTravelTime
    }
}
