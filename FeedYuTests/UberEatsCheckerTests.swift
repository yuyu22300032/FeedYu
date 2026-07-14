import XCTest
import CoreLocation
@testable import FeedYu

final class UberEatsCheckerTests: XCTestCase {
    // Synthetic results-page snippet: store hrefs mirror ubereats.com's
    // [/region]/store/<slug>/<uuid> shape (uuids are fake).
    private let resultsHTML = """
    <a href="/tw/store/mcdonalds-taipei-xinyi/aBcDeFgHiJkLmNoPqRsTuV">McDonald's</a>
    <a href="/tw/store/%E9%BC%8E%E6%B3%B0%E8%B1%90-taipei-101/QwErTyUiOpAsDfGhJkLzXc">鼎泰豐</a>
    <a href="/tw/store/mcdonalds-taipei-xinyi/aBcDeFgHiJkLmNoPqRsTuV">dupe</a>
    <a href="/store/burger-king-station/ZxCvBnMqWeRtYuIoPlKjHg">Burger King</a>
    """

    func testParsesAndDedupesStoreCandidates() {
        let candidates = UberEatsChecker.parseStoreCandidates(fromHTML: resultsHTML)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].slug, "mcdonalds-taipei-xinyi")
        // Region prefix kept, encoding kept (a decoded CJK path can't build
        // a URL), diningMode appended so the app opens ready to order.
        XCTAssertEqual(candidates[0].url.absoluteString,
                       "https://www.ubereats.com/tw/store/mcdonalds-taipei-xinyi/aBcDeFgHiJkLmNoPqRsTuV?diningMode=DELIVERY")
        XCTAssertEqual(candidates[1].slug, "鼎泰豐-taipei-101") // slug still percent-decoded for matching
        XCTAssertEqual(candidates[1].url.absoluteString,
                       "https://www.ubereats.com/tw/store/%E9%BC%8E%E6%B3%B0%E8%B1%90-taipei-101/QwErTyUiOpAsDfGhJkLzXc?diningMode=DELIVERY")
        XCTAssertEqual(candidates[2].url.absoluteString,
                       "https://www.ubereats.com/store/burger-king-station/ZxCvBnMqWeRtYuIoPlKjHg?diningMode=DELIVERY")
    }

    func testParsesEmbeddedFeedJSONStoreUUIDs() {
        // Search pages embed feed JSON; the canonical link is
        // /store-browse-uuid/<uuid> (the shape the Uber Eats app itself uses).
        let feedJSON = """
        {"storeUuid":"47559298-077C-4fe0-b151-2145215db10c","title":"老乾杯 慶城店","rating":4.8,
         "location":{"latitude":25.0790,"longitude":121.5750}},
        {"title":"別家店","storeUuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
        """
        let candidates = UberEatsChecker.parseStoreCandidates(fromHTML: feedJSON)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].slug, "老乾杯 慶城店")
        XCTAssertEqual(candidates[0].url.absoluteString,
                       "https://www.ubereats.com/store-browse-uuid/47559298-077c-4fe0-b151-2145215db10c?diningMode=DELIVERY")
        XCTAssertEqual(candidates[0].location?.coordinate.latitude ?? 0, 25.0790, accuracy: 0.0001,
                       "feed coordinates picked up — no store-page fetch needed")
        XCTAssertEqual(candidates[1].slug, "別家店", "title before the uuid is found too")
        XCTAssertNil(candidates[1].location)
    }

    func testNoStoreLinksMeansNoCandidates() {
        XCTAssertTrue(UberEatsChecker.parseStoreCandidates(
            fromHTML: "<html><body>Verify you are human</body></html>").isEmpty)
    }

    // Synthetic store page modeled on the schema.org JSON-LD Uber embeds.
    private let storePageHTML = """
    <script type="application/ld+json">
    {"@context":"http://schema.org","@type":"Restaurant","name":"鼎泰豐 (信義店)",
    "geo":{"@type":"GeoCoordinates","latitude":25.0333,"longitude":121.5654},
    "servesCuisine":["Taiwanese"]}
    </script>
    """

    func testParsesStorePageNameAndGeo() {
        let info = UberEatsChecker.parseStorePage(fromHTML: storePageHTML)
        XCTAssertEqual(info.name, "鼎泰豐 (信義店)")
        XCTAssertEqual(info.location?.coordinate.latitude ?? 0, 25.0333, accuracy: 0.0001)
        XCTAssertEqual(info.location?.coordinate.longitude ?? 0, 121.5654, accuracy: 0.0001)
    }

    func testParsesGetStoreV1APIResponse() {
        // The getStoreV1 API returns bare latitude/longitude (no "geo"
        // block) and "title" instead of a schema.org name.
        let json = #"{"status":"success","data":{"title":"三元花園韓式餐廳","location":{"address":"114台北市","latitude":25.0662,"longitude":121.5773}}}"#
        let info = UberEatsChecker.parseStorePage(fromHTML: json)
        XCTAssertEqual(info.name, "三元花園韓式餐廳")
        XCTAssertEqual(info.location?.coordinate.latitude ?? 0, 25.0662, accuracy: 0.0001)
    }

    func testStorePageWithoutJSONLDGeoHasNilLocation() {
        let info = UberEatsChecker.parseStorePage(fromHTML: "<html>menu stuff</html>")
        XCTAssertNil(info.location)
    }

    func testSearchURLEncodesName() {
        XCTAssertEqual(UberEatsChecker.searchURL(for: "鼎泰豐 信義店").absoluteString,
                       "https://www.ubereats.com/search?q=%E9%BC%8E%E6%B3%B0%E8%B1%90%20%E4%BF%A1%E7%BE%A9%E5%BA%97")
    }

    // Synthetic getStoreV1 fragment mirroring the live orderForLaterInfo
    // shape (semantics verified live 2026-07-10: future nextOpenTime =
    // closed right now; open stores report their most recent opening).
    func testParsesNextOpenTime() {
        let closed = #"{"data":{"title":"X","orderForLaterInfo":{"nextOpenTime":"2030-01-01T03:00:00.000Z","isSchedulable":true}}}"#
        let parsed = UberEatsChecker.parseNextOpenTime(fromStoreJSON: closed)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed! > Date(), "future nextOpenTime = closed now")

        let open = #"{"data":{"title":"X","orderForLaterInfo":{"nextOpenTime":"2020-01-01T23:00:00.000Z"}}}"#
        let past = UberEatsChecker.parseNextOpenTime(fromStoreJSON: open)
        XCTAssertNotNil(past)
        XCTAssertTrue(past! < Date(), "past nextOpenTime = open now")

        XCTAssertNil(UberEatsChecker.parseNextOpenTime(fromStoreJSON: #"{"data":{"title":"X"}}"#))
        XCTAssertNil(UberEatsChecker.parseNextOpenTime(fromStoreJSON: "<html>garbage</html>"))
    }

    func testCachedVerdictFreshness() {
        let now = Date()
        let url = URL(string: "https://www.ubereats.com/store-browse-uuid/x")
        // available goes stale after the TTL (a store open at noon may be
        // closed when the user returns to the tab).
        XCTAssertTrue(UberEatsChecker.isFresh(.available(url), checkedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(UberEatsChecker.isFresh(.available(url), checkedAt: now.addingTimeInterval(-11 * 60), now: now))
        // closedNow expires exactly at reopen time.
        XCTAssertTrue(UberEatsChecker.isFresh(.closedNow(url, reopens: now.addingTimeInterval(600)),
                                              checkedAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(UberEatsChecker.isFresh(.closedNow(url, reopens: now.addingTimeInterval(-1)),
                                               checkedAt: now, now: now))
        // Existence verdicts last the session.
        XCTAssertTrue(UberEatsChecker.isFresh(.notFound, checkedAt: .distantPast, now: now))
        XCTAssertTrue(UberEatsChecker.isFresh(.unknown, checkedAt: .distantPast, now: now))
    }

    func testStoreUUIDExtraction() {
        XCTAssertEqual(
            UberEatsChecker.storeUUID(fromStoreURL: URL(string: "https://www.ubereats.com/tw/store-browse-uuid/0f52222d-4b8e-49d0-ad7d-b9ae8b501ac1?diningMode=DELIVERY")!),
            "0f52222d-4b8e-49d0-ad7d-b9ae8b501ac1")
        XCTAssertNil(UberEatsChecker.storeUUID(fromStoreURL: URL(string: "https://www.ubereats.com/search?q=x")!))
    }

    func testNotFoundCooldownGate() {
        var r = Restaurant(name: "X")
        XCTAssertFalse(UberEatsChecker.isInNotFoundCooldown(r), "never checked → not in cooldown")
        r.uberEatsNotFoundAt = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        XCTAssertTrue(UberEatsChecker.isInNotFoundCooldown(r), "3 days old → still cooling down")
        r.uberEatsNotFoundAt = Date(timeIntervalSinceNow: -8 * 24 * 3600)
        XCTAssertFalse(UberEatsChecker.isInNotFoundCooldown(r), "8 days old → re-check allowed")
        r.uberEatsNotFoundAt = Date(timeIntervalSinceNow: -3600)
        r.uberEatsURL = URL(string: "https://www.ubereats.com/store-browse-uuid/x")
        XCTAssertFalse(UberEatsChecker.isInNotFoundCooldown(r), "a stored store link always wins")
    }

    func testSimilarityScores() {
        // Identical and containment (branch/city qualifiers on the slug).
        XCTAssertEqual(UberEatsChecker.similarity("mcdonalds", "mcdonalds"), 1)
        XCTAssertGreaterThanOrEqual(UberEatsChecker.similarity("mcdonalds", "mcdonaldstaipeixinyi"), 0.7)
        XCTAssertGreaterThanOrEqual(UberEatsChecker.similarity("鼎泰豐", "鼎泰豐taipei101"), 0.7)
        // Small typo-level distance still scores high.
        XCTAssertGreaterThan(UberEatsChecker.similarity("sushiro", "sushir0"), 0.8)
        // Different restaurants score low.
        XCTAssertLessThan(UberEatsChecker.similarity("burgerking", "mosburger"), 0.5)
        XCTAssertLessThan(UberEatsChecker.similarity("kfc", "pizzahut"), 0.3)
    }
}

/// End-to-end availability flow through the REAL retry/verdict logic, with
/// the WebView transport stubbed (UberEatsChecker.runJS) — the seam that
/// makes the open-check contracts machine-checkable instead of
/// device-testing folklore. See docs/REQUIREMENTS.md "Uber Eats".
@MainActor
final class UberEatsAvailabilityFlowTests: XCTestCase {
    private var checker: UberEatsChecker!

    override func setUp() async throws {
        checker = UberEatsChecker()
        UberEatsChecker.openCheckRetryDelayNanoseconds = 0
    }

    override func tearDown() async throws {
        UberEatsChecker.runJS = { script, arguments, hostPage in
            await WebPageFetcher.shared.callJS(script, arguments: arguments, onHost: hostPage)
        }
        UberEatsChecker.openCheckRetryDelayNanoseconds = 1_000_000_000
    }

    private func knownStore(name: String = "Known Store") -> Restaurant {
        var restaurant = Restaurant(name: name)
        restaurant.latitude = 25.03
        restaurant.longitude = 121.56
        restaurant.uberEatsURL = URL(string:
            "https://www.ubereats.com/store-browse-uuid/aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000?diningMode=DELIVERY")
        return restaurant
    }

    private static func storeJSON(nextOpenTime: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"200|{"data":{"orderForLaterInfo":{"nextOpenTime":"\#(formatter.string(from: nextOpenTime))"}}}"#
    }

    func testColdStartRetryRecoversTheOpenCheck() async {
        // REGRESSION (shipped): the Uber tab auto-rolls at launch, making
        // the open check the app's very FIRST WebView call — which
        // occasionally throws cold. Single-shot, the check failed open and
        // the initial card could be a store that is closed right now.
        var calls = 0
        let reopens = Date().addingTimeInterval(3 * 3600)
        UberEatsChecker.runJS = { _, _, _ in
            calls += 1
            return calls == 1 ? nil : Self.storeJSON(nextOpenTime: reopens)
        }
        let result = await checker.availability(for: knownStore(), near: nil)
        XCTAssertEqual(calls, 2, "first (cold) call failed — exactly one retry")
        guard case .closedNow(_, let cachedReopens) = result else {
            return XCTFail("closed store must be skipped, got \(result)")
        }
        XCTAssertEqual(cachedReopens.map { Int($0.timeIntervalSince1970) },
                       Int(reopens.timeIntervalSince1970))
    }

    func testClosedVerdictIsCachedUntilReopenTime() async {
        var calls = 0
        let reopens = Date().addingTimeInterval(3600)
        UberEatsChecker.runJS = { _, _, _ in
            calls += 1
            return Self.storeJSON(nextOpenTime: reopens)
        }
        let store = knownStore()
        _ = await checker.availability(for: store, near: nil)
        let second = await checker.availability(for: store, near: nil)
        XCTAssertEqual(calls, 1, "closed-until-a-known-time is not re-fetched before then")
        guard case .closedNow = second else { return XCTFail("still closed") }
    }

    func testOpenVerdictIsNeverCachedForKnownStores() async {
        // PRODUCT DECISION (do not "optimize" away): the card is the moment
        // before the user taps Order — a known store's OPEN state is
        // re-verified live on every suggestion, never served from a cache.
        var calls = 0
        let openedAt = Date().addingTimeInterval(-3600) // past = open now
        UberEatsChecker.runJS = { _, _, _ in
            calls += 1
            return Self.storeJSON(nextOpenTime: openedAt)
        }
        let store = knownStore()
        guard case .available = await checker.availability(for: store, near: nil) else {
            return XCTFail("open store is available")
        }
        guard case .available = await checker.availability(for: store, near: nil) else {
            return XCTFail("open store is available")
        }
        XCTAssertEqual(calls, 2, "open state re-checked on every call")
    }

    func testFailsOpenOnlyAfterRetryAlsoFails() async {
        // A persistent bot wall must not hide the user's whole verified
        // neighborhood — but the verdict is only surrendered after the
        // retry, not on the first cold hiccup.
        var calls = 0
        UberEatsChecker.runJS = { _, _, _ in calls += 1; return nil }
        let result = await checker.availability(for: knownStore(), near: nil)
        XCTAssertEqual(calls, 2, "both attempts spent before failing open")
        guard case .available = result else {
            return XCTFail("fail-open keeps the store visible, got \(result)")
        }
    }

    func testKnownStoreOpenCheckSendsTheLocation() async {
        // REGRESSION (shipped 2026-07-14): only the search pipeline set the
        // uev2.loc cookie, and it's session-scoped — so a cold launch's
        // known-store checks ran location-blind until some search happened
        // to run first. Without a location, getStoreV1 masks schedule
        // closure behind TOO_FAR_TO_DELIVER with a null nextOpenTime
        // (verified live against the shipped store): both closed signals
        // vanish, the check fails open, and a store that opens at 22:00
        // reached the lunch card.
        var capturedScript: String?
        var capturedLocJSON: String?
        UberEatsChecker.runJS = { script, arguments, _ in
            capturedScript = script
            capturedLocJSON = arguments["locJSON"] as? String
            return Self.storeJSON(nextOpenTime: Date().addingTimeInterval(-3600))
        }
        let origin = CLLocation(latitude: 25.0412825, longitude: 121.5678138)
        _ = await checker.availability(for: knownStore(), near: origin)
        XCTAssertEqual(capturedLocJSON, UberEatsChecker.locationJSON(for: origin),
                       "the open check must send the same location payload as the search pipeline")
        XCTAssertTrue(capturedScript?.contains("uev2.loc") == true,
                      "the open-check script must set the location cookie from locJSON")
    }
}

extension UberEatsAvailabilityFlowTests {
    func testPersistedClosedSuppressionSkipsTheLiveCheck() async {
        // A store verified closed persists its reopen stamp; a FRESH
        // checker (new launch, empty session cache) must skip the WebView
        // check entirely while the stamp is in the future.
        var calls = 0
        UberEatsChecker.runJS = { _, _, _ in calls += 1; return nil }
        var store = knownStore()
        store.uberEatsClosedUntil = Date().addingTimeInterval(2 * 3600)
        let result = await checker.availability(for: store, near: nil)
        XCTAssertEqual(calls, 0, "suppressed stores cost zero network")
        guard case .closedNow(_, let reopens) = result else {
            return XCTFail("still closed, got \(result)")
        }
        XCTAssertEqual(reopens, store.uberEatsClosedUntil)
    }

    func testExpiredSuppressionGoesBackToLiveChecking() async {
        // THE suppress-only guarantee: once the stamp passes, the live
        // open check decides again — the stamp can never ADMIT a store,
        // so an order button can never land on a known-closed page.
        var calls = 0
        let openedAt = Date().addingTimeInterval(-3600) // past = open now
        UberEatsChecker.runJS = { _, _, _ in
            calls += 1
            return Self.storeJSON(nextOpenTime: openedAt)
        }
        var store = knownStore()
        store.uberEatsClosedUntil = Date().addingTimeInterval(-60) // expired
        let result = await checker.availability(for: store, near: nil)
        XCTAssertEqual(calls, 1, "expired stamp → the live check ran")
        guard case .available = result else {
            return XCTFail("open store shows again, got \(result)")
        }
    }
}

/// Synthetic mirrors of REAL getStoreV1 captures (2026-07-11): a
/// merchant-paused taiyaki shop (the shipped miss), two schedule-closed
/// restaurants, and courier/UNKNOWN states. Real captures stay out of git.
extension UberEatsCheckerTests {
    func testParsesAvailabilityStateBothSpellings() {
        // Uber's own "Availablity" typo is live today; tolerate the
        // corrected spelling too so a silent fix upstream doesn't blind us.
        XCTAssertEqual(UberEatsChecker.parseAvailabilityState(
            fromStoreJSON: #"{"storeAvailablityStatus":{"state":"NOT_ACCEPTING_ORDERS","displayMessage":"x"}}"#),
            "NOT_ACCEPTING_ORDERS")
        XCTAssertEqual(UberEatsChecker.parseAvailabilityState(
            fromStoreJSON: #"{"storeAvailabilityStatus":{"state":"STORE_CLOSED"}}"#),
            "STORE_CLOSED")
    }

    func testMerchantPausedStoreIsClosedWithoutReopenTime() {
        // The taiyaki case: paused mid-shift, nextOpenTime null, and the
        // lying trio (isOpen/isOrderable/isAvailable) all true.
        let json = #"{"isOpen":true,"isOrderable":true,"isAvailable":true,"closedMessage":"paused","storeAvailablityStatus":{"state":"NOT_ACCEPTING_ORDERS","displayMessage":"paused"},"orderForLaterInfo":{"nextOpenTime":null}}"#
        let info = UberEatsChecker.parseClosedInfo(fromStoreJSON: json)
        XCTAssertTrue(info.closed, "a paused store is not orderable")
        XCTAssertNil(info.reopens, "merchant pauses carry no schedule moment")
    }

    func testScheduleClosedStoreCarriesReopenTime() {
        let json = #"{"storeAvailablityStatus":{"state":"STORE_CLOSED"},"orderForLaterInfo":{"nextOpenTime":"2026-07-11T09:00:00.000Z"}}"#
        let now = ISO8601DateFormatter().date(from: "2026-07-11T05:00:00Z")!
        let info = UberEatsChecker.parseClosedInfo(fromStoreJSON: json, now: now)
        XCTAssertTrue(info.closed)
        XCTAssertNotNil(info.reopens)
    }

    func testUnrecognizedStateFailsOpen() {
        // Deny-list discipline: courier/UNKNOWN states are ambiguous
        // without a confirmed open anchor — they must NOT hide a store.
        let json = #"{"storeAvailablityStatus":{"state":"NO_COURIERS_NEARBY"},"orderForLaterInfo":{"nextOpenTime":null}}"#
        XCTAssertFalse(UberEatsChecker.parseClosedInfo(fromStoreJSON: json).closed)
    }

    func testCachedMerchantPauseExpiresAfterTTL() {
        // closedNow with NO reopen moment must self-expire like the
        // persisted 10-minute fallback — distantFuture pinned it closed
        // for the whole session.
        let paused = UberEatsChecker.Availability.closedNow(nil, reopens: nil)
        let checkedAt = Date()
        XCTAssertTrue(UberEatsChecker.isFresh(paused, checkedAt: checkedAt,
                                              now: checkedAt.addingTimeInterval(5 * 60)))
        XCTAssertFalse(UberEatsChecker.isFresh(paused, checkedAt: checkedAt,
                                               now: checkedAt.addingTimeInterval(11 * 60)))
    }
}

extension UberEatsAvailabilityFlowTests {
    func testMerchantPausedKnownStoreIsSkippedEndToEnd() async {
        // The taiyaki regression, end to end: the old schedule-only check
        // read "nextOpenTime": null as OPEN and deep-linked the user to
        // Uber's "store indicated they aren't available" page.
        var calls = 0
        UberEatsChecker.runJS = { _, _, _ in
            calls += 1
            return #"200|{"isOpen":true,"isOrderable":true,"storeAvailablityStatus":{"state":"NOT_ACCEPTING_ORDERS"},"orderForLaterInfo":{"nextOpenTime":null}}"#
        }
        let result = await checker.availability(for: knownStore(), near: nil)
        XCTAssertEqual(calls, 1)
        guard case .closedNow(_, let reopens) = result else {
            return XCTFail("paused store must be skipped, got \(result)")
        }
        XCTAssertNil(reopens, "no schedule moment — the 10-minute fallback applies downstream")
    }
}
