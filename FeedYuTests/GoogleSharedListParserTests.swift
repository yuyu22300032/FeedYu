import XCTest
@testable import FeedYu

/// Parser tests against a saved fixture in the APP_INITIALIZATION_STATE
/// format. When Google changes the page, capture a new fixture from a real
/// shared-list URL and fix the parser until these pass again.
final class GoogleSharedListParserTests: XCTestCase {
    private func fixtureHTML() throws -> String {
        guard let url = Bundle(for: Self.self).url(forResource: "sharedlist", withExtension: "html") else {
            throw XCTSkip("Fixture missing from test bundle.")
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func testParsesAllPlacesFromFixture() throws {
        let places = GoogleSharedListSource.parsePlaces(fromHTML: try fixtureHTML())
        let names = places.map(\.name)
        XCTAssertTrue(names.contains("Sushi Saito"))
        XCTAssertTrue(names.contains("Florilège"))
        XCTAssertTrue(names.contains("Burnt Ends & Co."))
        XCTAssertTrue(names.contains("L'Ambroisie"))
    }

    func testCoordinatesAndFtid() throws {
        let places = GoogleSharedListSource.parsePlaces(fromHTML: try fixtureHTML())
        let saito = places.first { $0.name == "Sushi Saito" }
        XCTAssertEqual(saito?.latitude ?? 0, 35.6586, accuracy: 0.0001)
        XCTAssertEqual(saito?.longitude ?? 0, 139.7454, accuracy: 0.0001)
        XCTAssertEqual(saito?.ftid, "0x60188bbd9009ec09:0x481a93f0d2a409dd")
    }

    func testNeverCrashesOnGarbage() {
        XCTAssertEqual(GoogleSharedListSource.parsePlaces(fromHTML: ""), [])
        XCTAssertEqual(GoogleSharedListSource.parsePlaces(fromHTML: "<html>nothing here</html>"), [])
        XCTAssertEqual(GoogleSharedListSource.parsePlaces(fromHTML: "[null,null,999.0,999.0]\"Bad\""), [])
        // Unbalanced quotes / truncated blob must not crash either.
        _ = GoogleSharedListSource.parsePlaces(fromHTML: String(repeating: "[null,null,1.5,", count: 1000))
    }

    func testNamePlausibility() {
        XCTAssertFalse(GoogleSharedListSource.isPlausibleName("https://maps.google.com/x"))
        XCTAssertFalse(GoogleSharedListSource.isPlausibleName("0x60188bbd9009ec09:0x481a93f0d2a409dd"))
        XCTAssertFalse(GoogleSharedListSource.isPlausibleName("35.6586,139.7454"))
        XCTAssertFalse(GoogleSharedListSource.isPlausibleName("JP"))
        XCTAssertTrue(GoogleSharedListSource.isPlausibleName("Sushi Saito"))
        XCTAssertTrue(GoogleSharedListSource.isPlausibleName("Florilège"))
    }

    func testDecodesUnicodeEscapes() {
        XCTAssertEqual(GoogleSharedListSource.decodeJSStringEscapes(#"Café \"Le\" Test"#), #"Café "Le" Test"#)
    }

    /// CJK is caseless, so the "short ALL-CAPS code" filter must not fire on
    /// it — 2–3-character CJK restaurant names were silently dropped (17
    /// places of one real list: 雅閣, 歸香, 天香樓…).
    func testShortCJKNamesAreValidRestaurantNames() {
        for name in ["松滿樓", "雅閣", "歸香", "煉瓦亭", "天香樓"] {
            XCTAssertTrue(GoogleSharedListSource.isPlausibleName(name), name)
        }
        // The codes the rule exists for still get rejected.
        XCTAssertFalse(GoogleSharedListSource.isPlausibleName("JP"))
        XCTAssertFalse(GoogleSharedListSource.isPlausibleName("USD"))
    }

    /// Two different restaurants in the same building share coordinates to
    /// 4 decimals — the old coordinate-keyed dedupe collapsed them.
    func testNeighboringPlacesAtTheSameAddressBothParse() {
        let html = """
        APP_INITIALIZATION_STATE
        [null,null,25.0402,121.5349]"松滿樓"
        [null,null,25.0402,121.5349]"隔壁小館"
        """
        XCTAssertEqual(GoogleSharedListSource.parsePlaces(fromHTML: html).map(\.name),
                       ["松滿樓", "隔壁小館"])
    }
}
