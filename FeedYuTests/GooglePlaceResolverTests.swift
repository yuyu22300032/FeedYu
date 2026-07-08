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

    // Two DIFFERENT places ~11 m and ~28 m from the target — inside the
    // ambiguity margin of each other (food-court case): refuse to guess.
    func testTwoPlacesAlmostEquallyCloseIsAmbiguous() {
        let html = """
        ["a"]!1s0x3442abd88ffb8341:0x0000000000000aaa!8m2!3d25.03340!4d121.56540!16s
        ["b"]!1s0x3442abd88ffb8342:0x0000000000000bbb!8m2!3d25.03355!4d121.56545!16s
        """
        XCTAssertNil(GooglePlaceResolver.extractCid(fromHTML: html,
                                                    near: CLLocationCoordinate2D(latitude: 25.0333, longitude: 121.5654)))
    }

    // Both in the bubble but ~11 m vs ~122 m — clearly separable: nearest wins.
    func testClearlySeparatedInBubblePicksNearest() {
        let html = """
        ["a"]!1s0x3442abd88ffb8341:0x0000000000000aaa!8m2!3d25.03340!4d121.56540!16s
        ["b"]!1s0x3442abd88ffb8342:0x0000000000000bbb!8m2!3d25.03440!4d121.56540!16s
        """
        let cid = GooglePlaceResolver.extractCid(fromHTML: html,
                                                 near: CLLocationCoordinate2D(latitude: 25.0333, longitude: 121.5654))
        XCTAssertEqual(cid, "2730")  // 0xaaa
    }

    // The SAME place repeated in the page (typical) must not read as
    // ambiguity — dedupe is by cid, not by occurrence.
    func testSameCidRepeatedIsNotAmbiguous() {
        let html = """
        ["a"]!1s0x3442abd88ffb8341:0x0000000000000aaa!8m2!3d25.03340!4d121.56540!16s
        ["a2"]!1s0x3442abd88ffb8341:0x0000000000000aaa!8m2!3d25.03341!4d121.56541!16s
        """
        let cid = GooglePlaceResolver.extractCid(fromHTML: html,
                                                 near: CLLocationCoordinate2D(latitude: 25.0333, longitude: 121.5654))
        XCTAssertEqual(cid, "2730")
    }

    // MARK: - Outcome classification (drives the retry-vs-cache decision)

    private let taipei = CLLocationCoordinate2D(latitude: 25.0333, longitude: 121.5654)

    func testDatalessShellPageIsUnavailable() {
        // Google sometimes serves a valid Maps page with NO embedded result
        // data (JS shell) — observed live 2026-07-08. Transient: retry-worthy.
        let shell = "<html><title>Google 地圖</title>window.APP_INITIALIZATION_STATE=[[null]];</html>"
        XCTAssertEqual(GooglePlaceResolver.resolution(fromHTML: shell, near: taipei), .unavailable)
    }

    func testDataBearingPageWithNoNearbyResultIsNoMatch() {
        XCTAssertEqual(GooglePlaceResolver.resolution(fromHTML: searchHTML,
                                                      near: CLLocationCoordinate2D(latitude: 24.0, longitude: 120.0)),
                       .noMatch)
    }

    func testAmbiguousTieIsNoMatchNotUnavailable() {
        // Retrying won't break a tie — cache it for the session.
        let html = """
        ["a"]!1s0x3442abd88ffb8341:0x0000000000000aaa!8m2!3d25.03340!4d121.56540!16s
        ["b"]!1s0x3442abd88ffb8342:0x0000000000000bbb!8m2!3d25.03355!4d121.56545!16s
        """
        XCTAssertEqual(GooglePlaceResolver.resolution(fromHTML: html, near: taipei), .noMatch)
    }

    func testMatchClassifiesAsResolved() {
        XCTAssertEqual(GooglePlaceResolver.resolution(fromHTML: searchHTML, near: taipei),
                       .resolved("11259375"))
    }
}
