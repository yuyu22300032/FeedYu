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
