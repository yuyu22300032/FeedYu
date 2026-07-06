import XCTest
@testable import FeedYu

final class UberEatsCheckerTests: XCTestCase {
    // Synthetic results-page snippet: store hrefs mirror ubereats.com's
    // /store/<slug>/<uuid> shape (uuids are fake).
    private let resultsHTML = """
    <a href="/store/mcdonalds-taipei-xinyi/aBcDeFgHiJkLmNoPqRsTuV">McDonald's</a>
    <a href="/store/%E9%BC%8E%E6%B3%B0%E8%B1%90-taipei-101/QwErTyUiOpAsDfGhJkLzXc">鼎泰豐</a>
    <a href="/store/burger-king-station/ZxCvBnMqWeRtYuIoPlKjHg">Burger King</a>
    """

    func testFindsMatchingStoreAndCapturesURL() {
        let result = UberEatsChecker.parseAvailability(fromHTML: resultsHTML, name: "McDonald's")
        guard case .available(let url) = result else {
            return XCTFail("expected available, got \(result)")
        }
        XCTAssertEqual(url?.absoluteString,
                       "https://www.ubereats.com/store/mcdonalds-taipei-xinyi/aBcDeFgHiJkLmNoPqRsTuV")
    }

    func testMatchesPercentEncodedCJKSlugWithBranchSuffix() {
        // Our stored name carries a branch suffix; the slug carries a city
        // qualifier — the shared prefix rule bridges them.
        let result = UberEatsChecker.parseAvailability(fromHTML: resultsHTML, name: "鼎泰豐 信義店")
        guard case .available(let url) = result else {
            return XCTFail("expected available, got \(result)")
        }
        XCTAssertEqual(url?.absoluteString.contains("/store/"), true)
    }

    func testRealResultsWithoutMatchIsNotFound() {
        XCTAssertEqual(UberEatsChecker.parseAvailability(fromHTML: resultsHTML, name: "Sukiyabashi Jiro"),
                       .notFound)
    }

    func testPageWithoutStoreLinksIsUnknown() {
        // Bot-wall interstitial / location picker → can't tell → permissive.
        XCTAssertEqual(UberEatsChecker.parseAvailability(fromHTML: "<html><body>Verify you are human</body></html>",
                                                         name: "McDonald's"),
                       .unknown)
    }

    func testSearchURLEncodesName() {
        XCTAssertEqual(UberEatsChecker.searchURL(for: "鼎泰豐 信義店").absoluteString,
                       "https://www.ubereats.com/search?q=%E9%BC%8E%E6%B3%B0%E8%B1%90%20%E4%BF%A1%E7%BE%A9%E5%BA%97")
    }

    func testNamesMatchRules() {
        XCTAssertTrue(UberEatsChecker.namesMatch("mcdonalds", "mcdonaldstaipeixinyi"))   // containment
        XCTAssertTrue(UberEatsChecker.namesMatch("鼎泰豐信義店", "鼎泰豐taipei101"))         // 3-char CJK prefix
        XCTAssertTrue(UberEatsChecker.namesMatch("starbucksreserve", "starbucksxinyi"))  // 6+ latin prefix
        XCTAssertFalse(UberEatsChecker.namesMatch("pizzahut", "pizzamania"))             // 5-char latin prefix
        XCTAssertFalse(UberEatsChecker.namesMatch("burgerking", "mosburger"))
        XCTAssertFalse(UberEatsChecker.namesMatch("kfc", "kfx"))
    }
}
