import XCTest
@testable import FeedYu

final class AppSettingsTests: XCTestCase {
    /// Each page's budget carries its own mode AND per-mode values —
    /// switching modes must not forget the other modes' settings.
    func testPageBudgetModesRememberTheirOwnValues() {
        var budget = AppSettings.PageBudget()
        XCTAssertEqual(budget.travelBudget.mode, .driving)
        XCTAssertEqual(budget.travelBudget.value, 60)

        budget.mode = .walking
        budget.setValue(30)
        XCTAssertEqual(budget.travelBudget.value, 30)

        budget.mode = .driving
        XCTAssertEqual(budget.travelBudget.value, 60, "drive minutes survived the walk edit")
        XCTAssertEqual(budget.walkMinutes, 30, "walk minutes remembered for next switch")

        budget.mode = .distance
        budget.setValue(5000)
        XCTAssertEqual(budget.travelBudget.value, 5000)
        XCTAssertEqual(budget.driveMinutes, 60)
    }

    func testPageBudgetRoundTripsThroughJSON() throws {
        var budget = AppSettings.PageBudget()
        budget.mode = .walking
        budget.walkMinutes = 45
        let decoded = try JSONDecoder().decode(AppSettings.PageBudget.self,
                                               from: JSONEncoder().encode(budget))
        XCTAssertEqual(decoded, budget)
    }
}
