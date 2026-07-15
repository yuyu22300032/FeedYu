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

    /// When `current` last passed the full acceptance gauntlet (budget +
    /// availability). Consulted only when an `availabilityCheck` exists:
    /// its verdicts age (stores close overnight while the app sits
    /// suspended with the card still up), so a revalidation against an
    /// old affirmation must not leave the card interactive while it
    /// re-verifies.
    private(set) var currentAffirmedAt: Date?
    /// How long an affirmation keeps revalidation silent — the Uber tab
    /// wires this to `UberEatsChecker.openStateTTL`; tests shrink it to
    /// force the stale path.
    var affirmationTTL: TimeInterval = 600

    /// Injectable for tests. Default uses MKDirections.calculateETA with
    /// departure = now (traffic-aware for driving), no API key needed.
    var etaProvider: (CLLocationCoordinate2D, CLLocationCoordinate2D, TravelMode) async throws -> TimeInterval = SuggestionEngine.mapKitETA

    /// MapKit throttles directions requests — bound the work per refresh.
    var maxETAChecksPerRefresh = 12

    /// Optional post-selection filter (Uber Eats tab: "is it orderable?").
    /// Runs after a candidate passes the travel budget; false drops the
    /// candidate for the session and the search continues. Counted against
    /// the per-refresh check budget — implementations should cache.
    var availabilityCheck: ((Restaurant) async -> Bool)?

    /// Optional free, synchronous rejection (Uber Eats tab: places with a
    /// fresh verified "not on Uber Eats"). Unlike availabilityCheck, NOT
    /// counted against the check budget — without this, a neighborhood of
    /// known-unorderable places exhausts the budget and the tab shows "no
    /// results" even though an orderable place sits later in the queue.
    var quickReject: ((Restaurant) -> Bool)?

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
    var etaCacheTTL: TimeInterval = 600 // var: tests shrink it to force re-queries

    func reset() {
        current = nil
        currentAffirmedAt = nil
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
        await performRefresh(candidates: candidates, origin: origin, budget: budget)
    }

    /// Guard-free core of `refreshSuggestion`: `revalidateCurrent`
    /// escalates here while it already holds `isSearching` for a
    /// stale-affirmation re-verification — the public guard would turn
    /// that escalation into a silent no-op and keep the rejected card.
    private func performRefresh(candidates: [Restaurant], origin: CLLocation, budget: TravelBudget) async {
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
            restartRotation()
        }

        var checks = 0
        // A drained queue wraps the rotation and rescans once (flag-bounded)
        // — without this, "you've already seen every orderable place" ended
        // the refresh with "nothing new, press again", demanding a pointless
        // extra press before the next refresh's queue-empty reshuffle could
        // run. Rescans are cheap: the ETA cache and notFound cooldowns skip
        // the known answers.
        var wrapped = false
        search: while true {
            while !queue.isEmpty {
                // A cancelled search (view task torn down, tab left) stops
                // here instead of finishing the scan — on the Uber tab each
                // further step is a slow WebView check for a card nobody is
                // looking at. The queue keeps its position, so the next
                // refresh resumes where this one stopped.
                if Task.isCancelled { return }
                let candidate = queue.removeFirst()
                guard let coordinate = candidate.coordinate else { continue }
                if let quickReject, quickReject(candidate) { continue }

                // Distance mode: the pool is already exactly within the radius —
                // no route lookup, but the availability filter still applies.
                guard budget.needsETACheck else {
                    if let availabilityCheck {
                        guard checks < maxETAChecksPerRefresh else {
                            queue.insert(candidate, at: 0)
                            pauseForCheckBudget()
                            break search
                        }
                        checks += 1
                        guard await availabilityCheck(candidate) else { continue }
                    }
                    accept(candidate, etaSeconds: nil, origin: origin, mode: budget.mode)
                    return
                }

                guard checks < maxETAChecksPerRefresh else {
                    queue.insert(candidate, at: 0)
                    pauseForCheckBudget()
                    break search
                }
                checks += 1
                do {
                    let eta = try await cachedETA(id: candidate.id, from: origin, to: coordinate, mode: budget.mode)
                    if eta <= budget.maxTravelSeconds {
                        if let availabilityCheck, await !availabilityCheck(candidate) {
                            continue // in range but not orderable — roll another
                        }
                        accept(candidate, etaSeconds: eta, origin: origin, mode: budget.mode)
                        return
                    }
                    // Over budget by the real route — drop it for this session.
                } catch let error as MKError where error.code == .loadingThrottled {
                    queue.insert(candidate, at: 0)
                    statusMessage = String(localized: "Apple Maps is rate-limiting drive-time checks. Wait a minute and refresh.")
                    return
                } catch {
                    // Cancellation surfaces here too (MapKit fails the
                    // in-flight await): the candidate got no verdict, so it
                    // keeps its queue position, and a deliberate cancel
                    // must not be blamed on the network.
                    if Task.isCancelled {
                        queue.insert(candidate, at: 0)
                        return
                    }
                    statusMessage = String(localized: "Couldn't check drive time for some places (network?).")
                }
            }
            guard !wrapped, !shownIDs.isEmpty else { break }
            wrapped = true
            restartRotation()
        }
        if queue.isEmpty && shownIDs.isEmpty {
            current = nil
            statusMessage = String(localized: "Nothing reachable within \(budget.label) right now.")
        } else if statusMessage == nil {
            statusMessage = String(localized: "Nothing new within \(budget.label) so far — refresh to keep looking.")
        }
    }

    /// Re-check the CURRENT suggestion against a possibly changed world —
    /// traffic, moved origin, availability (Uber open hours) — keeping the
    /// card when it still fits (suggestions stay stable across tab
    /// switches) and silently rolling a replacement when it doesn't.
    /// Cheap when caches are fresh; call on tab appearance and on
    /// foreground return. A still-valid drive/walk pick gets its traffic
    /// minutes refreshed in place.
    ///
    /// Two exceptions to "silently", both born 2026-07-15 (an app
    /// suspended overnight resumed with last night's card interactive —
    /// its Order button opened a store that had closed hours earlier,
    /// while the live re-check was still in flight):
    /// - With an `availabilityCheck` present, a card whose affirmation is
    ///   older than `affirmationTTL` re-verifies as a REAL search:
    ///   `isSearching` raises, so the view's loading takeover pulls the
    ///   card instead of leaving a live button on last night's verdict.
    ///   Fresh affirmations keep the silent path — casual tab switches
    ///   never blink the card.
    /// - A card the checks REJECT (persisted closed stamp, live verdict)
    ///   is cleared before the replacement scan starts: a scan that
    ///   pauses at the check budget without accepting anyone (a morning
    ///   where the whole neighborhood is closed) must not resurface a
    ///   card that is KNOWN to be unorderable.
    func revalidateCurrent(candidates: [Restaurant], origin: CLLocation, budget: TravelBudget) async {
        guard let suggestion = current, !isSearching,
              let coordinate = suggestion.restaurant.coordinate else { return }

        // Stale-affirmation hold. Every other search entry point (button,
        // auto-suggest, revalidation) guards on isSearching, so while the
        // hold is up a raised flag can only be OURS — the post-await
        // "user rolled meanwhile" guards below tolerate exactly that.
        let affirmationExpired = availabilityCheck != nil &&
            Date().timeIntervalSince(currentAffirmedAt ?? .distantPast) >= affirmationTTL
        if affirmationExpired { isSearching = true }
        // Escalations re-manage the flag inside performRefresh; this
        // releases the hold on the keep-the-card and bail-out paths (a
        // second `false` after an escalation is harmless).
        defer { if affirmationExpired { isSearching = false } }

        // Filters are constraints too: if the current pick fell out of the
        // candidate set (Michelin price/award filters, list toggles), it
        // no longer qualifies regardless of travel budget.
        guard candidates.contains(where: { $0.id == suggestion.restaurant.id }) else {
            await performRefresh(candidates: candidates, origin: origin, budget: budget)
            return
        }

        if let quickReject, quickReject(suggestion.restaurant) {
            current = nil // known-unorderable — must not outlive its rejection
            await performRefresh(candidates: candidates, origin: origin, budget: budget)
            return
        }

        if budget.needsETACheck {
            guard let eta = try? await cachedETA(id: suggestion.restaurant.id, from: origin,
                                                 to: coordinate, mode: budget.mode) else { return }
            // The user may have rolled while we awaited — never fight them.
            guard current?.id == suggestion.id, !isSearching || affirmationExpired else { return }
            if eta > budget.maxTravelSeconds {
                await performRefresh(candidates: candidates, origin: origin, budget: budget)
                return
            }
            if let availabilityCheck, await !availabilityCheck(suggestion.restaurant) {
                guard current?.id == suggestion.id, !isSearching || affirmationExpired else { return }
                current = nil // rejected by a LIVE verdict — never resurface
                await performRefresh(candidates: candidates, origin: origin, budget: budget)
                return
            }
            guard current?.id == suggestion.id else { return }
            accept(suggestion.restaurant, etaSeconds: eta, origin: origin, mode: budget.mode)
        } else {
            if (suggestion.restaurant.distance(from: origin) ?? .infinity) > budget.radiusMeters {
                await performRefresh(candidates: candidates, origin: origin, budget: budget)
                return
            }
            if let availabilityCheck, await !availabilityCheck(suggestion.restaurant) {
                guard current?.id == suggestion.id, !isSearching || affirmationExpired else { return }
                current = nil // rejected by a LIVE verdict — never resurface
                await performRefresh(candidates: candidates, origin: origin, budget: budget)
                return
            }
            guard current?.id == suggestion.id else { return }
            // Survived — but the travel line must match the (possibly
            // switched) mode: a drive→distance switch shows "X km away",
            // not the stale "5 min in current traffic".
            accept(suggestion.restaurant, etaSeconds: nil, origin: origin, mode: budget.mode)
        }
    }

    /// Batch paused mid-queue (check budget spent, more candidates left):
    /// say what happened and invite continuation — the generic "nothing
    /// new" line read as a dead end. Deliberately vague on the count: a
    /// precise number would be wrong in both directions (quickReject skips
    /// pass over stores without counting, and the counted number is always
    /// just the batch cap at this point).
    private func pauseForCheckBudget() {
        statusMessage = availabilityCheck != nil
            ? String(localized: "Checked many stores — refresh to keep looking.")
            : String(localized: "Checked many places — refresh to keep looking.")
    }

    /// Rotation exhausted: reshuffle the whole pool, avoiding an immediate
    /// repeat of the current card, and say so.
    private func restartRotation() {
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

    private func accept(_ candidate: Restaurant, etaSeconds: TimeInterval?, origin: CLLocation, mode: TravelMode) {
        shownIDs.insert(candidate.id)
        currentAffirmedAt = Date()
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
