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
        // Uber tab config: distance mode + Int.max budget = keep checking
        // until something is orderable or the whole pool was checked — no
        // more "no new places in range, press again" mid-queue give-ups.
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
