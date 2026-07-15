import XCTest
import CoreLocation
@testable import FeedYu

@MainActor
final class SuggestionEngineTests: XCTestCase {
    private let origin = CLLocation(latitude: 35.6812, longitude: 139.7671) // Tokyo Station

    private func place(_ name: String, latOffset: Double) -> Restaurant {
        var r = Restaurant(name: name)
        r.latitude = 35.6812 + latOffset
        r.longitude = 139.7671
        r.lists = [.wantToGo]
        return r
    }

    private func drive(_ minutes: Int) -> TravelBudget { TravelBudget(mode: .driving, value: minutes) }

    func testNoRepeatsUntilPoolExhausted() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in 20 * 60 } // everything 20 min away
        let candidates = (0..<5).map { place("R\($0)", latOffset: Double($0) * 0.001) }

        var seen: [String] = []
        for _ in 0..<5 {
            await engine.refreshSuggestion(candidates: candidates, origin: origin, budget: drive(60))
            if let name = engine.current?.restaurant.name { seen.append(name) }
        }
        XCTAssertEqual(Set(seen).count, 5, "all 5 shown once before any repeat")

        // 6th refresh: pool exhausted → reshuffles and repeats.
        await engine.refreshSuggestion(candidates: candidates, origin: origin, budget: drive(60))
        XCTAssertNotNil(engine.current)
        XCTAssertNotNil(engine.statusMessage)
    }

    func testRejectsCandidatesOverBudget() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, destination, _ in
            // "Far" ones (offset >= 0.01°) take 90 min, near ones 15 min.
            destination.latitude > 35.687 ? 90 * 60 : 15 * 60
        }
        let near = place("Near", latOffset: 0.001)
        let far = place("Far", latOffset: 0.02)
        for _ in 0..<2 {
            await engine.refreshSuggestion(candidates: [near, far], origin: origin, budget: drive(30))
            XCTAssertEqual(engine.current?.restaurant.name, "Near")
        }
    }

    func testStraightLinePrefilterExcludesHopelesslyFar() async {
        let engine = SuggestionEngine()
        var etaCalls = 0
        engine.etaProvider = { _, _, _ in etaCalls += 1; return 10 * 60 }
        let paris = { () -> Restaurant in
            var r = Restaurant(name: "Paris")
            r.latitude = 48.85; r.longitude = 2.35
            return r
        }()
        await engine.refreshSuggestion(candidates: [paris], origin: origin, budget: drive(30))
        XCTAssertNil(engine.current)
        XCTAssertEqual(etaCalls, 0, "no ETA call for a candidate outside the straight-line radius")
    }

    func testETACacheAvoidsDuplicateCalls() async {
        let engine = SuggestionEngine()
        var etaCalls = 0
        engine.etaProvider = { _, _, _ in etaCalls += 1; return 10 * 60 }
        let only = place("Only", latOffset: 0.001)
        await engine.refreshSuggestion(candidates: [only], origin: origin, budget: drive(60))
        await engine.refreshSuggestion(candidates: [only], origin: origin, budget: drive(60))
        XCTAssertEqual(etaCalls, 1, "second suggestion for the same place reuses the cached ETA")
    }

    func testEmptyCandidates() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in 10 * 60 }
        await engine.refreshSuggestion(candidates: [], origin: origin, budget: drive(60))
        XCTAssertNil(engine.current)
        XCTAssertNotNil(engine.statusMessage)
    }

    // MARK: - Travel modes

    func testDistanceModeMakesNoRouteCalls() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in
            XCTFail("distance mode must not request routes")
            return 0
        }
        let near = place("Near", latOffset: 0.001) // ~111 m
        await engine.refreshSuggestion(candidates: [near], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "Near")
        XCTAssertNil(engine.current?.etaMinutes)
        XCTAssertEqual(engine.current?.travelMode, .distance)
    }

    func testDistanceModeIsExact() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in 0 }
        let outside = place("Outside", latOffset: 0.01) // ~1.1 km
        await engine.refreshSuggestion(candidates: [outside], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertNil(engine.current, "1.1 km away must not pass a 500 m budget")
    }

    func testWalkingModeVerifiesWithWalkingRoutes() async {
        let engine = SuggestionEngine()
        var modes: [TravelMode] = []
        engine.etaProvider = { _, _, mode in
            modes.append(mode)
            return 12 * 60
        }
        let near = place("Near", latOffset: 0.005) // ~550 m
        await engine.refreshSuggestion(candidates: [near], origin: origin,
                                       budget: TravelBudget(mode: .walking, value: 15))
        XCTAssertEqual(engine.current?.restaurant.name, "Near")
        XCTAssertEqual(engine.current?.etaMinutes, 12)
        XCTAssertEqual(modes, [.walking])
    }

    func testAvailabilityCheckDropsCandidateAndRollsAnother() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in 10 * 60 }
        let unavailable = place("NotOnUber", latOffset: 0.001)
        let available = place("OnUber", latOffset: 0.002)
        engine.availabilityCheck = { $0.name == "OnUber" }
        for _ in 0..<3 {
            await engine.refreshSuggestion(candidates: [unavailable, available],
                                           origin: origin, budget: drive(60))
            XCTAssertEqual(engine.current?.restaurant.name, "OnUber")
        }
    }

    func testAvailabilityCheckAppliesInDistanceMode() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in
            XCTFail("distance mode must not request routes")
            return 0
        }
        var checked: [String] = []
        engine.availabilityCheck = { restaurant in
            checked.append(restaurant.name)
            return restaurant.name == "OnUber"
        }
        let candidates = [place("NotOnUber", latOffset: 0.001), place("OnUber", latOffset: 0.002)]
        await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "OnUber")
        XCTAssertTrue(checked.contains("NotOnUber") || checked == ["OnUber"])
    }

    func testUncappedBudgetChecksEveryPlaceInOneRefresh() async {
        // Engine capability: with an uncapped budget a single refresh keeps
        // checking until something is orderable or the whole pool was
        // checked. (The Uber tab now runs bounded batches of 25 that resume
        // across presses — see testCappedScanResumesAcrossRefreshes — but
        // the uncapped behavior must keep working for any budget value.)
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode must not request routes"); return 0 }
        engine.maxETAChecksPerRefresh = Int.max
        var checkedCount = 0
        engine.availabilityCheck = { checkedCount += 1; return $0.name == "OnUber" }
        var candidates = (0..<20).map { place("No\($0)", latOffset: Double($0) * 0.0001) }
        // ~444 m: alone in the outermost distance ring (rings are 500/3 m),
        // so the shuffled queue is guaranteed to reach it last.
        candidates.append(place("OnUber", latOffset: 0.004))
        await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "OnUber",
                       "a single refresh reaches the orderable place at the end of the queue")
        XCTAssertEqual(checkedCount, 21, "everything before it was checked, then it stopped")
    }

    func testRotationWrapsInsteadOfDemandingAnExtraPress() async {
        // One orderable place among not-orderable neighbors: after it has
        // been shown, the next refresh used to drain the queue and end with
        // "nothing new — refresh to keep looking"; it must wrap the rotation
        // and re-serve the orderable place in the same refresh.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode must not request routes"); return 0 }
        engine.maxETAChecksPerRefresh = Int.max
        engine.availabilityCheck = { $0.name == "OnUber" }
        let candidates = [place("No0", latOffset: 0.0001),
                          place("No1", latOffset: 0.0002),
                          place("OnUber", latOffset: 0.0003)]
        for attempt in 0..<3 {
            await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                           budget: TravelBudget(mode: .distance, value: 500))
            XCTAssertEqual(engine.current?.restaurant.name, "OnUber",
                           "refresh #\(attempt) must land on the only orderable place, never give up")
        }
    }

    func testCappedScanResumesAcrossRefreshes() async {
        // The Uber tab bounds each refresh to a batch of slow availability
        // checks. A scan that pauses mid-queue must NOT give up or restart:
        // the paused candidate is requeued at the front, a status message
        // says keep looking, and the next press continues from there —
        // every place still gets checked exactly once.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode must not request routes"); return 0 }
        engine.maxETAChecksPerRefresh = 2
        var checkedCount = 0
        engine.availabilityCheck = { checkedCount += 1; return $0.name == "OnUber" }
        var candidates = (0..<5).map { place("No\($0)", latOffset: Double($0) * 0.0001) }
        // Alone in the outermost distance ring → guaranteed last in queue.
        candidates.append(place("OnUber", latOffset: 0.004))

        for press in 0..<2 {
            await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                           budget: TravelBudget(mode: .distance, value: 500))
            XCTAssertNil(engine.current, "press #\(press) pauses mid-queue")
            XCTAssertNotNil(engine.statusMessage, "paused scan invites another press")
        }
        await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "OnUber",
                       "third press resumes the queue and reaches the orderable place")
        XCTAssertEqual(checkedCount, 6, "no place was re-checked while resuming")
    }

    func testCancelledRefreshStopsScanning() async {
        // Leaving the tab cancels the search task; the engine must stop
        // burning availability checks for a card nobody is looking at.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode must not request routes"); return 0 }
        var checkedCount = 0
        engine.availabilityCheck = { _ in checkedCount += 1; return false }
        let candidates = (0..<10).map { place("No\($0)", latOffset: Double($0) * 0.0001) }

        let search = Task { @MainActor in
            await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                           budget: TravelBudget(mode: .distance, value: 500))
        }
        search.cancel() // lands before the MainActor task body runs
        await search.value
        XCTAssertEqual(checkedCount, 0, "a cancelled refresh checks nothing")
        XCTAssertFalse(engine.isSearching)

        // The queue survived the cancellation — the next (uncancelled)
        // refresh scans it normally.
        await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(checkedCount, 10, "resumed refresh checks the full pool")
    }

    func testCancellationDuringETAIsSilentAndKeepsTheCandidate() async {
        // A cancellation that lands while awaiting a route check surfaces
        // as a thrown error — it must not be blamed on the network, and
        // the unverdicted candidate must keep its queue position.
        let engine = SuggestionEngine()
        var etaCalls = 0
        var search: Task<Void, Never>?
        engine.etaProvider = { _, _, _ in
            etaCalls += 1
            search?.cancel() // cancellation lands mid-await
            throw CancellationError()
        }
        let candidates = [place("A", latOffset: 0.001), place("B", latOffset: 0.002)]
        search = Task { @MainActor in
            await engine.refreshSuggestion(candidates: candidates, origin: origin, budget: drive(30))
        }
        await search?.value
        XCTAssertNil(engine.current)
        XCTAssertNil(engine.statusMessage, "a deliberate cancel is not a network error")
        XCTAssertEqual(etaCalls, 1)

        // Next refresh finds the requeued candidate still first in line.
        engine.etaProvider = { _, _, _ in etaCalls += 1; return 10 * 60 }
        await engine.refreshSuggestion(candidates: candidates, origin: origin, budget: drive(30))
        XCTAssertNotNil(engine.current)
        XCTAssertEqual(etaCalls, 2, "no candidate was lost to the cancelled check")
    }

    func testQuickRejectIsFreeAndDoesNotExhaustBudget() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode must not request routes"); return 0 }
        engine.maxETAChecksPerRefresh = 2
        var checked: [String] = []
        engine.availabilityCheck = { checked.append($0.name); return true }
        engine.quickReject = { $0.name.hasPrefix("No") }
        // Eight known-notFound places nearer than the orderable one: counted
        // against the 2-check budget these exhausted it and the tab showed
        // "no results" (the real bug); quick-rejection must be free.
        var candidates = (0..<8).map { place("No\($0)", latOffset: Double($0) * 0.0001) }
        candidates.append(place("OnUber", latOffset: 0.002))
        await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "OnUber")
        XCTAssertEqual(checked, ["OnUber"], "quick-rejected places never reach the counted check")
    }

    // MARK: - Revalidation on tab return

    func testRevalidateKeepsFittingPickAndRefreshesTraffic() async {
        let engine = SuggestionEngine()
        engine.etaCacheTTL = 0 // force a fresh route query on revalidation
        var etaMinutes = 20.0
        engine.etaProvider = { _, _, _ in etaMinutes * 60 }
        let only = place("Only", latOffset: 0.001)
        await engine.refreshSuggestion(candidates: [only], origin: origin, budget: drive(30))
        XCTAssertEqual(engine.current?.etaMinutes, 20)

        etaMinutes = 25 // traffic worsened, still within budget
        await engine.revalidateCurrent(candidates: [only], origin: origin, budget: drive(30))
        XCTAssertEqual(engine.current?.restaurant.name, "Only", "still fits — card survives")
        XCTAssertEqual(engine.current?.etaMinutes, 25, "traffic label refreshed in place")
    }

    func testRevalidateRollsReplacementWhenOverBudget() async {
        let engine = SuggestionEngine()
        engine.etaCacheTTL = 0
        var slowNames: Set<String> = []
        engine.etaProvider = { _, destination, _ in
            // "Far" flag by latitude: candidates keyed by their offsets.
            slowNames.contains(String(format: "%.4f", destination.latitude)) ? 90 * 60 : 15 * 60
        }
        let a = place("A", latOffset: 0.001)
        let b = place("B", latOffset: 0.002)
        await engine.refreshSuggestion(candidates: [a, b], origin: origin, budget: drive(30))
        guard let first = engine.current?.restaurant else { return XCTFail("no pick") }

        // The chosen one's route degrades past the budget.
        slowNames = [String(format: "%.4f", first.latitude!)]
        await engine.revalidateCurrent(candidates: [a, b], origin: origin, budget: drive(30))
        XCTAssertNotNil(engine.current)
        XCTAssertNotEqual(engine.current?.restaurant.name, first.name,
                          "over-budget pick replaced silently")
    }

    func testRevalidateSwitchesTravelLineWithTheMode() async {
        // drive → distance: the surviving card must show "X km away", not
        // the stale drive minutes.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in 20 * 60 }
        let only = place("Only", latOffset: 0.001) // ~111 m
        await engine.refreshSuggestion(candidates: [only], origin: origin, budget: drive(30))
        XCTAssertEqual(engine.current?.travelMode, .driving)
        XCTAssertEqual(engine.current?.etaMinutes, 20)

        await engine.revalidateCurrent(candidates: [only], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "Only", "still fits — survives")
        XCTAssertEqual(engine.current?.travelMode, .distance)
        XCTAssertNil(engine.current?.etaMinutes, "distance mode shows km, not minutes")
    }

    func testRevalidateReplacesWhenCurrentLeavesCandidateSet() async {
        // Filters are constraints: Michelin's price/award chips narrow the
        // candidate set — a current pick that fell out must be replaced,
        // one still inside must survive.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode"); return 0 }
        let a = place("A", latOffset: 0.001)
        let b = place("B", latOffset: 0.002)
        await engine.refreshSuggestion(candidates: [a, b], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        guard let first = engine.current?.restaurant else { return XCTFail("no pick") }
        let survivor = first.name == "A" ? b : a

        // Still in the set → survives.
        await engine.revalidateCurrent(candidates: [a, b], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, first.name)

        // Filtered out → replaced by one that qualifies.
        await engine.revalidateCurrent(candidates: [survivor], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, survivor.name)
    }

    func testRevalidateRollsWhenAvailabilityFlips() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode"); return 0 }
        var orderable: Set<String> = ["A", "B"]
        engine.availabilityCheck = { orderable.contains($0.name) }
        let a = place("A", latOffset: 0.001)
        let b = place("B", latOffset: 0.002)
        await engine.refreshSuggestion(candidates: [a, b], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        guard let first = engine.current?.restaurant else { return XCTFail("no pick") }

        orderable.remove(first.name) // the store closed while browsing elsewhere
        await engine.revalidateCurrent(candidates: [a, b], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertNotEqual(engine.current?.restaurant.name, first.name,
                          "closed store replaced on revalidation")
    }

    func testFreshAffirmationRevalidatesSilently() async {
        // Casual tab switches must not blink the card: a card affirmed
        // moments ago re-verifies without raising isSearching.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode"); return 0 }
        var searchingDuringCheck: [Bool] = []
        engine.availabilityCheck = { [weak engine] _ in
            searchingDuringCheck.append(engine?.isSearching ?? false)
            return true
        }
        let only = place("Only", latOffset: 0.001)
        await engine.refreshSuggestion(candidates: [only], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(searchingDuringCheck, [true], "the roll path is a search")

        await engine.revalidateCurrent(candidates: [only], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(searchingDuringCheck, [true, false],
                       "a fresh affirmation re-verifies without the loading takeover")
        XCTAssertEqual(engine.current?.restaurant.name, "Only")
    }

    func testStaleAffirmationRevalidatesBehindTheLoadingState() async {
        // The 2026-07-15 regression: an app suspended overnight resumed
        // with last night's card interactive while its slow re-check ran,
        // and the Order button opened a closed store. A stale affirmation
        // must run the revalidation as a REAL search — isSearching up, so
        // the view's loading takeover pulls the card.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode"); return 0 }
        var searchingDuringCheck: [Bool] = []
        engine.availabilityCheck = { [weak engine] _ in
            searchingDuringCheck.append(engine?.isSearching ?? false)
            return true
        }
        let only = place("Only", latOffset: 0.001)
        await engine.refreshSuggestion(candidates: [only], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        guard let affirmedOnRoll = engine.currentAffirmedAt else { return XCTFail("no stamp") }

        engine.affirmationTTL = 0 // every verdict is instantly "last night's"
        await engine.revalidateCurrent(candidates: [only], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(searchingDuringCheck, [true, true],
                       "a stale affirmation re-verifies as a real search")
        XCTAssertFalse(engine.isSearching, "hold released once the verdict lands")
        XCTAssertEqual(engine.current?.restaurant.name, "Only", "re-affirmed card survives")
        XCTAssertNotEqual(engine.currentAffirmedAt, affirmedOnRoll, "affirmation restamped")
    }

    func testStaleRevalidationStillEscalatesIntoReplacement() async {
        // The stale hold raises isSearching BEFORE any escalation into a
        // full refresh — that refresh must not be blocked by its own
        // re-entry guard, or the closed card silently survives.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode"); return 0 }
        var orderable: Set<String> = ["A", "B"]
        engine.availabilityCheck = { orderable.contains($0.name) }
        let a = place("A", latOffset: 0.001)
        let b = place("B", latOffset: 0.002)
        await engine.refreshSuggestion(candidates: [a, b], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        guard let first = engine.current?.restaurant else { return XCTFail("no pick") }

        orderable.remove(first.name) // closed overnight
        engine.affirmationTTL = 0
        await engine.revalidateCurrent(candidates: [a, b], origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertNotNil(engine.current, "replacement rolled")
        XCTAssertNotEqual(engine.current?.restaurant.name, first.name,
                          "stale closed card replaced, not kept")
        XCTAssertFalse(engine.isSearching)
    }

    func testRejectedCardNeverSurvivesAPausedReplacementScan() async {
        // Side door of the same 2026-07-15 bug: the replacement scan can
        // pause at the check budget without accepting anyone (a morning
        // where the whole neighborhood is closed) — the card whose LIVE
        // verdict just came back "closed" must not resurface behind the
        // "refresh to keep looking" message.
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _, _ in XCTFail("distance mode"); return 0 }
        let candidates = (0..<6).map { place("R\($0)", latOffset: Double($0) * 0.0001) }

        // Seed a current card by permitting exactly one acceptance (the
        // default check budget comfortably covers the 6-candidate scan).
        engine.availabilityCheck = { $0.name == "R0" }
        await engine.refreshSuggestion(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertEqual(engine.current?.restaurant.name, "R0")

        engine.availabilityCheck = { _ in false } // R0 closed too, like the rest
        engine.maxETAChecksPerRefresh = 2 // force the replacement scan to pause
        engine.affirmationTTL = 0
        await engine.revalidateCurrent(candidates: candidates, origin: origin,
                                       budget: TravelBudget(mode: .distance, value: 500))
        XCTAssertNil(engine.current, "known-closed card gone even though the scan paused")
        XCTAssertNotNil(engine.statusMessage, "the pause still invites a refresh")
        XCTAssertFalse(engine.isSearching)
    }

    func testModeSwitchInvalidatesSessionAndETACache() async {
        let engine = SuggestionEngine()
        var etaCalls = 0
        engine.etaProvider = { _, _, _ in etaCalls += 1; return 10 * 60 }
        let only = place("Only", latOffset: 0.001)
        await engine.refreshSuggestion(candidates: [only], origin: origin, budget: drive(60))
        await engine.refreshSuggestion(candidates: [only], origin: origin,
                                       budget: TravelBudget(mode: .walking, value: 30))
        XCTAssertEqual(etaCalls, 2, "walking ETA is not served from the driving cache")
    }
}
