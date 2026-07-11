import XCTest

/// Machine-checks the view-wiring contracts in docs/REQUIREMENTS.md that
/// unit tests cannot reach — the tier where the 2026-07-11 regressions
/// (dead pane on launch, budget change doing nothing) hid until human
/// testing found them.
///
/// Runs against the app's DEBUG seed hook (`-uiTestSeed near|far`,
/// UITestSeed.swift): synthetic store, fixed location, distance-only
/// budget — no network or CoreLocation in any assertion path.
///
/// Run (own scheme keeps the unit suite fast):
///   xcodebuild test -project FeedYu.xcodeproj -scheme FeedYuDemo \
///     -only-testing:FeedYuUITests/SuggestionContractUITests \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
final class SuggestionContractUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// resetFilters keeps runs idempotent on a reused simulator; the
    /// persistence test relaunches with `false` so the Michelin filter
    /// keys travel through the real persistence path. initialTab uses the
    /// app's own automation hook — tab-bar taps don't register reliably
    /// under XCUITest with the page-style TabView, and offscreen pages'
    /// elements `exist` without being hittable.
    private func launch(scenario: String, initialTab: String? = nil,
                        resetFilters: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", scenario, "-AppleLanguages", "(en)"]
        if let initialTab {
            app.launchArguments += ["-initialTab", initialTab]
        }
        if resetFilters {
            app.launchArguments += ["-uiTestResetFilters", "1"]
        }
        app.launch()
        return app
    }

    /// The suggestion card's restaurant name (every seeded place is
    /// "Seed …", so this matches iff a card is showing).
    private func seedCard(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Seed '")).firstMatch
    }

    private func expectSelected(_ element: XCUIElement,
                                _ message: String = "chip reports selected") {
        let selected = expectation(for: NSPredicate(format: "isSelected == true"),
                                   evaluatedWith: element)
        wait(for: [selected], timeout: 5)
        XCTAssertTrue(element.isSelected, message)
    }

    func testColdLaunchLandsOnACardWithZeroTaps() {
        // REQUIREMENTS "Panes are eager": opening the app auto-rolls a
        // suggestion once store + location are ready — no interaction.
        let app = launch(scenario: "near")
        XCTAssertTrue(seedCard(in: app).waitForExistence(timeout: 15),
                      "cold launch must land on a suggestion card by itself")
    }

    func testBudgetChangeWithNoCardRollsOne() {
        // REQUIREMENTS: with no card up, a constraint change rolls a fresh
        // one — "try a bigger budget" must not demand a button press.
        // Scenario "far": the only place is ~3.3 km out, budget 500 m.
        let app = launch(scenario: "far")
        XCTAssertFalse(seedCard(in: app).waitForExistence(timeout: 8),
                       "nothing is within the seeded 500 m budget")
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 1.0) // widest preset
        XCTAssertTrue(seedCard(in: app).waitForExistence(timeout: 10),
                      "widening the budget must produce a card with zero taps")
    }

    func testHideReplacesTheCardImmediately() {
        // REQUIREMENTS: hiding the current card replaces it right away —
        // the just-hidden restaurant must not linger until a manual roll.
        let app = launch(scenario: "near")
        let card = seedCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let shown = card.label

        card.press(forDuration: 1.2)
        let hide = app.buttons["Hide this restaurant"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "context menu opens")
        hide.tap()

        let replacement = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Seed ' AND label != %@", shown)).firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 10),
                      "a different seeded place replaces the hidden one")
        XCTAssertFalse(app.staticTexts[shown].exists, "the hidden restaurant is gone")
    }

    func testMichelinFiltersPersistAcrossRelaunch() {
        // REQUIREMENTS: price/award filters persist across launches.
        var app = launch(scenario: "near", initialTab: "michelin")
        let chip = app.buttons["$$$"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertFalse(chip.isSelected, "defaults are $ + $$")
        chip.tap()
        expectSelected(chip)

        app.terminate()
        app = launch(scenario: "near", initialTab: "michelin", resetFilters: false)
        let after = app.buttons["$$$"]
        XCTAssertTrue(after.waitForExistence(timeout: 10))
        expectSelected(after, "the $$$ selection survived the relaunch")
    }
}
