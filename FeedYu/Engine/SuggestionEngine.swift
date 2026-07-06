import Foundation
import CoreLocation
import MapKit

struct Suggestion: Identifiable, Equatable {
    var restaurant: Restaurant
    var etaMinutes: Int?          // nil in distance mode (no route lookup)
    var straightLineKm: Double
    var travelMode: TravelMode = .driving
    var id: UUID { restaurant.id }
}

/// Shuffled no-repeat suggestion queue with lazy, cached route checks.
/// One instance per tab (each tab has its own no-repeat session).
///
/// Cost model (deliberate): the straight-line prefilter is free; route ETAs
/// are only requested for the candidate being suggested, one at a time.
/// Distance mode never touches routing at all.
@MainActor
final class SuggestionEngine: ObservableObject {
    @Published private(set) var current: Suggestion?
    @Published private(set) var isSearching = false
    @Published private(set) var statusMessage: String?

    /// Injectable for tests. Default uses MKDirections.calculateETA with
    /// departure = now (traffic-aware for driving), no API key needed.
    var etaProvider: (CLLocationCoordinate2D, CLLocationCoordinate2D, TravelMode) async throws -> TimeInterval = SuggestionEngine.mapKitETA

    /// MapKit throttles directions requests — bound the work per refresh.
    var maxETAChecksPerRefresh = 12

    private var queue: [Restaurant] = []
    private var shownIDs: Set<UUID> = []
    private var sessionOrigin: CLLocation?
    private var sessionBudget: TravelBudget?
    private var sessionCandidateIDs: Set<UUID> = []
    /// In-range candidates for the session, from one grid query at session
    /// start — refreshes stop paying an O(all candidates) distance scan.
    private var sessionPool: [Restaurant] = []

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
        sessionBudget = nil
        queue = []
        shownIDs = []
        sessionPool = []
    }

    /// Pops the next candidate within the travel budget. No repeats until
    /// the in-range pool is exhausted, then reshuffles.
    func refreshSuggestion(candidates: [Restaurant], origin: CLLocation, budget: TravelBudget) async {
        guard !isSearching else { return }
        isSearching = true
        statusMessage = nil
        defer { isSearching = false }

        ensureSession(candidates: candidates, origin: origin, budget: budget)

        if sessionPool.isEmpty {
            current = nil
            statusMessage = String(localized: "No restaurants within roughly \(budget.label) of you. Try a bigger budget or add more places.")
            return
        }

        if queue.isEmpty {
            // Exhausted: reshuffle the whole pool, avoiding an immediate repeat.
            shownIDs = []
            rebuildQueue(from: sessionPool)
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
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            guard let coordinate = candidate.coordinate else { continue }

            // Distance mode: the pool is already exactly within the radius —
            // accept without any route lookup.
            guard budget.needsETACheck else {
                accept(candidate, etaSeconds: nil, origin: origin, mode: budget.mode)
                return
            }

            guard checks < maxETAChecksPerRefresh else {
                queue.insert(candidate, at: 0)
                break
            }
            checks += 1
            do {
                let eta = try await cachedETA(id: candidate.id, from: origin, to: coordinate, mode: budget.mode)
                if eta <= budget.maxTravelSeconds {
                    accept(candidate, etaSeconds: eta, origin: origin, mode: budget.mode)
                    return
                }
                // Over budget by the real route — drop it for this session.
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
            statusMessage = String(localized: "Nothing reachable within \(budget.label) right now.")
        } else if statusMessage == nil {
            statusMessage = String(localized: "Nothing new within \(budget.label) so far — refresh to keep looking.")
        }
    }

    private func accept(_ candidate: Restaurant, etaSeconds: TimeInterval?, origin: CLLocation, mode: TravelMode) {
        shownIDs.insert(candidate.id)
        let km = (candidate.distance(from: origin) ?? 0) / 1000
        current = Suggestion(restaurant: candidate,
                             etaMinutes: etaSeconds.map { Int(($0 / 60).rounded()) },
                             straightLineKm: km,
                             travelMode: mode)
    }

    // MARK: - Session

    private func ensureSession(candidates: [Restaurant], origin: CLLocation, budget: TravelBudget) {
        let ids = Set(candidates.map(\.id))
        // Origin drift tolerance scales down with tight radii — a 2 km walk
        // budget must not keep serving a pool centered 1.9 km away.
        let driftTolerance = min(2000, budget.radiusMeters * 0.5)
        if let sessionOrigin,
           sessionOrigin.distance(from: origin) < driftTolerance,
           sessionBudget == budget,
           sessionCandidateIDs == ids {
            return
        }
        self.sessionOrigin = origin
        sessionBudget = budget
        sessionCandidateIDs = ids
        shownIDs = []
        // One layered-grid query here replaces a full distance scan on every
        // refresh. Exact radius for distance mode; generous straight-line
        // bound for walk/drive (the per-candidate route check does the truth).
        sessionPool = SpatialGrid(candidates).query(around: origin, radiusMeters: budget.radiusMeters)
        rebuildQueue(from: sessionPool)
    }

    /// Random within distance rings, nearest ring first: try places in the
    /// same "city" as the user before neighboring ones — early route checks
    /// mostly pass, so fewer MapKit calls are wasted.
    private func rebuildQueue(from pool: [Restaurant]) {
        let remaining = pool.filter { !shownIDs.contains($0.id) }
        guard let origin = sessionOrigin, let budget = sessionBudget else {
            queue = remaining.shuffled()
            return
        }
        let ringMeters = max(1.0, budget.radiusMeters / 3)
        var rings: [Int: [Restaurant]] = [:]
        for candidate in remaining {
            let distance = candidate.distance(from: origin) ?? .greatestFiniteMagnitude
            rings[Int(distance / ringMeters), default: []].append(candidate)
        }
        queue = rings.keys.sorted().flatMap { rings[$0]!.shuffled() }
    }

    // MARK: - ETA

    private func cachedETA(id: UUID, from origin: CLLocation, to destination: CLLocationCoordinate2D, mode: TravelMode) async throws -> TimeInterval {
        // Origin bucketed to a ~500 m grid so tiny GPS jitter reuses the cache.
        let key = "\(id.uuidString)|\(mode.rawValue)|\(Int(origin.coordinate.latitude * 200))|\(Int(origin.coordinate.longitude * 200))"
        if let cached = etaCache[key], Date().timeIntervalSince(cached.date) < etaCacheTTL {
            return cached.seconds
        }
        let eta = try await etaProvider(origin.coordinate, destination, mode)
        etaCache[key] = CachedETA(seconds: eta, date: Date())
        return eta
    }

    static func mapKitETA(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, mode: TravelMode) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = mode == .walking ? .walking : .automobile
        request.departureDate = Date()
        let response = try await MKDirections(request: request).calculateETA()
        return response.expectedTravelTime
    }
}
