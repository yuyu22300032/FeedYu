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
