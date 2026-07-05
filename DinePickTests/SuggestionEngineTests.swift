import XCTest
import CoreLocation
@testable import DinePick

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

    func testNoRepeatsUntilPoolExhausted() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _ in 20 * 60 } // everything 20 min away
        let candidates = (0..<5).map { place("R\($0)", latOffset: Double($0) * 0.001) }

        var seen: [String] = []
        for _ in 0..<5 {
            await engine.refreshSuggestion(candidates: candidates, origin: origin, budgetMinutes: 60)
            if let name = engine.current?.restaurant.name { seen.append(name) }
        }
        XCTAssertEqual(Set(seen).count, 5, "all 5 shown once before any repeat")

        // 6th refresh: pool exhausted → reshuffles and repeats.
        await engine.refreshSuggestion(candidates: candidates, origin: origin, budgetMinutes: 60)
        XCTAssertNotNil(engine.current)
        XCTAssertNotNil(engine.statusMessage)
    }

    func testRejectsCandidatesOverBudget() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, destination in
            // "Far" ones (offset >= 0.01°) take 90 min, near ones 15 min.
            destination.latitude > 35.687 ? 90 * 60 : 15 * 60
        }
        let near = place("Near", latOffset: 0.001)
        let far = place("Far", latOffset: 0.02)
        for _ in 0..<2 {
            await engine.refreshSuggestion(candidates: [near, far], origin: origin, budgetMinutes: 30)
            XCTAssertEqual(engine.current?.restaurant.name, "Near")
        }
    }

    func testStraightLinePrefilterExcludesHopelesslyFar() async {
        let engine = SuggestionEngine()
        var etaCalls = 0
        engine.etaProvider = { _, _ in etaCalls += 1; return 10 * 60 }
        let paris = { () -> Restaurant in
            var r = Restaurant(name: "Paris")
            r.latitude = 48.85; r.longitude = 2.35
            return r
        }()
        await engine.refreshSuggestion(candidates: [paris], origin: origin, budgetMinutes: 30)
        XCTAssertNil(engine.current)
        XCTAssertEqual(etaCalls, 0, "no ETA call for a candidate outside the straight-line radius")
    }

    func testETACacheAvoidsDuplicateCalls() async {
        let engine = SuggestionEngine()
        var etaCalls = 0
        engine.etaProvider = { _, _ in etaCalls += 1; return 10 * 60 }
        let only = place("Only", latOffset: 0.001)
        await engine.refreshSuggestion(candidates: [only], origin: origin, budgetMinutes: 60)
        await engine.refreshSuggestion(candidates: [only], origin: origin, budgetMinutes: 60)
        XCTAssertEqual(etaCalls, 1, "second suggestion for the same place reuses the cached ETA")
    }

    func testEmptyCandidates() async {
        let engine = SuggestionEngine()
        engine.etaProvider = { _, _ in 10 * 60 }
        await engine.refreshSuggestion(candidates: [], origin: origin, budgetMinutes: 60)
        XCTAssertNil(engine.current)
        XCTAssertNotNil(engine.statusMessage)
    }
}
