import XCTest
@testable import FeedYu

final class GoogleMapsOpenerTests: XCTestCase {
    func testStoredCidURLWinsUnchanged() {
        var r = Restaurant(name: "有 cid 的店")
        r.googleMapsURL = URL(string: "https://maps.google.com/?cid=7347522595497240971")
        r.latitude = 25.03
        r.longitude = 121.56
        XCTAssertEqual(GoogleMapsOpener.url(for: r).absoluteString,
                       "https://maps.google.com/?cid=7347522595497240971")
    }

    func testNoCidWithCoordinatesAnchorsSearchAtPlace() {
        var r = Restaurant(name: "老乾杯 慶城店")
        r.latitude = 25.052437
        r.longitude = 121.545618
        let url = GoogleMapsOpener.url(for: r).absoluteString
        XCTAssertTrue(url.hasPrefix("https://www.google.com/maps/search/"), url)
        XCTAssertTrue(url.contains("@25.052437,121.545618,17z"), url)
        XCTAssertFalse(url.contains(" "), "name must be fully percent-encoded")
    }

    func testNameWithSlashCannotBreakThePath() {
        var r = Restaurant(name: "Fish & Chips / 炸魚薯條")
        r.latitude = 25.0
        r.longitude = 121.5
        let url = GoogleMapsOpener.url(for: r).absoluteString
        XCTAssertFalse(url.contains("Fish & Chips /"), "raw slash would split the path segment")
        XCTAssertTrue(url.contains("@25.000000,121.500000,17z"), url)
    }

    func testCachedLocalNameWinsOverRomanizationInSearch() {
        // Google can't match "Uosho" near the Taipei anchor — the listing
        // is 魚庄. The local-market name must drive the search fallback.
        var r = Restaurant(name: "Uosho")
        r.address = "24, Lane 83, Section 1, Zhongshan North Road, Taipei, TWN"
        r.localizedNames = ["zh_TW": "魚庄"]
        r.latitude = 25.0499609
        r.longitude = 121.5238215
        let url = GoogleMapsOpener.url(for: r).absoluteString
        XCTAssertTrue(url.contains("%E9%AD%9A%E5%BA%84"), url)  // 魚庄, UTF-8 percent-encoded
        XCTAssertFalse(url.contains("Uosho"), url)
    }

    func testLocalizedNameForOtherMarketIsIgnored() {
        // Only the place's own market's name helps the anchored search; a
        // zh_TW name cached for a Tokyo place must not leak into the query.
        var r = Restaurant(name: "Sushi Saito")
        r.address = "1-4-5 Roppongi, Minato-ku, Tokyo, JPN"
        r.localizedNames = ["zh_TW": "鮨齋藤"]
        r.latitude = 35.6664
        r.longitude = 139.7413
        let url = GoogleMapsOpener.url(for: r).absoluteString
        XCTAssertTrue(url.contains("SushiSaito") || url.contains("Sushi%20Saito"), url)
    }

    func testNoCoordinatesFallsBackToTextQuery() {
        var r = Restaurant(name: "Somewhere")
        r.address = "1 Main St"
        let url = GoogleMapsOpener.url(for: r).absoluteString
        XCTAssertTrue(url.contains("api=1"), url)
        XCTAssertTrue(url.contains("query=Somewhere"), url)
    }

    func testMapsNoMatchCooldownGate() {
        var r = Restaurant(name: "Uosho")
        XCTAssertFalse(PlaceInfoFetcher.isInNoMatchCooldown(r, searchName: "Uosho"))
        r.mapsNoMatchAt = Date(timeIntervalSinceNow: -24 * 3600)
        r.mapsNoMatchName = "Uosho"
        XCTAssertTrue(PlaceInfoFetcher.isInNoMatchCooldown(r, searchName: "Uosho"))
        XCTAssertFalse(PlaceInfoFetcher.isInNoMatchCooldown(r, searchName: "魚庄"),
                       "a newly localized name earns a fresh attempt despite the cooldown")
        r.mapsNoMatchAt = Date(timeIntervalSinceNow: -31 * 24 * 3600)
        XCTAssertFalse(PlaceInfoFetcher.isInNoMatchCooldown(r, searchName: "Uosho"),
                       "expired cooldown re-checks")
    }

    func testExactPlaceURLPredicate() {
        // Exact: cid/ftid links (scraper, Takeout GeoJSON) and place paths.
        XCTAssertTrue(GoogleMapsOpener.isExactPlaceURL(URL(string: "https://maps.google.com/?cid=123")!))
        XCTAssertTrue(GoogleMapsOpener.isExactPlaceURL(URL(string: "https://maps.google.com/?ftid=0x1:0x2")!))
        XCTAssertTrue(GoogleMapsOpener.isExactPlaceURL(URL(string: "https://www.google.com/maps/place/Everywhere/@25,121,17z/data=!3m1")!))
        // Not exact: Takeout list-CSV search exports and api=1 queries.
        XCTAssertFalse(GoogleMapsOpener.isExactPlaceURL(URL(string: "https://www.google.com/maps/search/Everywhere/data=!4m2!3m1")!))
        XCTAssertFalse(GoogleMapsOpener.isExactPlaceURL(URL(string: "https://www.google.com/maps/search/?api=1&query=Everywhere")!))
    }
}
