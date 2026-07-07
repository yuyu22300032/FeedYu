import XCTest
import CoreLocation
@testable import FeedYu

final class GooglePlaceResolverTests: XCTestCase {
    // Synthetic search-page fragment mirroring the !1s<ftid> … !3d!4d tokens
    // (ids are fake). First result ~11 km away, second at the target.
    private let searchHTML = """
    ["x"]!1s0x3442abd88ffb8341:0xff00000000000001!8m2!3d25.1330!4d121.5654!16s
    ["y"]!1s0x3442abd88ffb8342:0x0000000000abcdef!8m2!3d25.0334!4d121.5655!16s
    ["z"]0x3442abd88ffb8343:0x00000000000000ff no pin after this one
    """

    func testPicksTheResultNearOurCoordinates() {
        let cid = GooglePlaceResolver.extractCid(fromHTML: searchHTML,
                                                 near: CLLocationCoordinate2D(latitude: 25.0333, longitude: 121.5654))
        // 0xabcdef = 11259375 decimal — the documented ludocid conversion.
        XCTAssertEqual(cid, "11259375")
    }

    func testNoResultWithinRadiusMeansNil() {
        let cid = GooglePlaceResolver.extractCid(fromHTML: searchHTML,
                                                 near: CLLocationCoordinate2D(latitude: 24.0, longitude: 120.0))
        XCTAssertNil(cid)
    }

    func testGarbageHTMLMeansNil() {
        XCTAssertNil(GooglePlaceResolver.extractCid(fromHTML: "<html>consent wall</html>",
                                                    near: CLLocationCoordinate2D(latitude: 25, longitude: 121)))
    }
}
