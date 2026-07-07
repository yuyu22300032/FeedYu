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

    func testNoCoordinatesFallsBackToTextQuery() {
        var r = Restaurant(name: "Somewhere")
        r.address = "1 Main St"
        let url = GoogleMapsOpener.url(for: r).absoluteString
        XCTAssertTrue(url.contains("api=1"), url)
        XCTAssertTrue(url.contains("query=Somewhere"), url)
    }
}
