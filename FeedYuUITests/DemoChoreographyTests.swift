import XCTest

/// Not a correctness test: a scripted walkthrough used to film the App
/// Store preview (docs/DEVELOPMENT.md "App Preview video"). Runs in its own
/// scheme (FeedYuDemo) so the normal test command never pays for it.
/// Timing is choreography — the sleeps ARE the scene lengths.
///
/// Assumes a simulator seeded with a real store + prefs (zh-Hant labels;
/// see the screenshot recipe in DEVELOPMENT.md). Every step is
/// best-effort: a missing element skips its beat instead of failing the
/// take mid-recording.
final class DemoChoreographyTests: XCTestCase {
    func testDemoChoreography() throws {
        let app = XCUIApplication()
        app.launch()

        // Scene 1 — Tonight: a pick from your own lists, then push the
        // walk budget up and watch the suggestion re-roll to match.
        sleep(6)
        let slider = app.sliders.firstMatch
        if slider.waitForExistence(timeout: 3) {
            slider.adjust(toNormalizedSliderPosition: 0.55)
        }
        sleep(5)

        // Scene 2 — drive mode in current traffic + "not feeling it".
        tap("開車", in: app)
        sleep(3)
        tapButtonContaining("換一間", in: app)
        sleep(5)

        // Scene 3 — Michelin: filters, a roll, a peek at the in-range list.
        tap("米其林", in: app)
        sleep(2)
        tapButtonContaining("⭐️", in: app)
        sleep(1)
        tapButtonContaining("隨機推薦", in: app)
        sleep(5)
        app.swipeUp()
        sleep(2)

        // Scene 4 — Uber Eats: verified orderable, straight to the store.
        tap("Uber Eats", in: app)
        sleep(7)
    }

    private func tap(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
        } else {
            let text = app.staticTexts[label].firstMatch
            if text.exists { text.tap() }
        }
    }

    private func tapButtonContaining(_ fragment: String, in app: XCUIApplication) {
        let button = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() }
    }
}
