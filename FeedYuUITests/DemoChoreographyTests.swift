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
    /// Storefront language for the take: `TEST_RUNNER_DEMO_LANGUAGE=en|ja`
    /// on the xcodebuild invocation (defaults to the seeded prefs' zh-Hant).
    /// The taps below query by LOCALIZED label, so language and labels
    /// must travel together.
    private var language: String {
        ProcessInfo.processInfo.environment["DEMO_LANGUAGE"] ?? "zh-Hant"
    }

    private var labels: (drive: String, michelin: String, another: String, suggest: String) {
        switch language {
        case "en": return ("Drive", "Michelin", "another", "Suggest a restaurant")
        case "ja": return ("車", "ミシュラン", "別のお店", "レストランを提案")
        default: return ("開車", "米其林", "換一間", "隨機推薦")
        }
    }

    private var guideLabels: (next: String, start: String) {
        switch language {
        case "en": return ("Continue", "Get started")
        case "ja": return ("次へ", "はじめる")
        default: return ("繼續", "開始使用")
        }
    }

    func testDemoChoreography() throws {
        let app = XCUIApplication()
        if language != "zh-Hant" {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
        }
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
        tap(labels.drive, in: app)
        sleep(3)
        tapButtonContaining(labels.another, in: app)
        sleep(5)

        // Scene 3 — Michelin: filters, a roll, a peek at the in-range list.
        tap(labels.michelin, in: app)
        sleep(2)
        tapButtonContaining("⭐️", in: app)
        sleep(1)
        tapButtonContaining(labels.suggest, in: app)
        sleep(5)
        app.swipeUp()
        sleep(2)

        // Scene 4 — Uber Eats: verified orderable, straight to the store.
        tap("Uber Eats", in: app)
        sleep(7)
    }

    /// Second preview take: "setup is easy" — the first-launch guide's two
    /// import pages (own list, friend's list) acted out by their vignettes,
    /// a beat on the budget page, then dismissal onto Tonight for the
    /// payoff pick. `-hasSeenOnboarding NO` (argument domain) forces the
    /// sheet; `-onboardingPage 1` opens it straight on the import page.
    /// Film with `-only-testing:FeedYuUITests/DemoChoreographyTests/testSetupChoreography`.
    func testSetupChoreography() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenOnboarding", "NO", "-onboardingPage", "1"]
        if language != "zh-Hant" {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
        }
        app.launch()

        // Scene 1 — "Bring your Google Maps lists": let the share-flow
        // vignette play past a full loop (~7 s) so the edit can pick a
        // clean one.
        sleep(16)

        // Scene 2 — "Import a friend's list": same, full vignette loop.
        tap(guideLabels.next, in: app)
        sleep(16)

        // Scene 3 — budget modes, a short beat.
        tap(guideLabels.next, in: app)
        sleep(6)

        // Scene 4 — done: onto Tonight with a real pick from the seeded
        // store.
        tap(guideLabels.start, in: app)
        sleep(10)
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
