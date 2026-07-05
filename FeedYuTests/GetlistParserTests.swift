import XCTest
@testable import FeedYu

/// Regression tests for the current two-step shared-list format: the list
/// page embeds a tokenized entitylist/getlist XHR URL, whose response carries
/// the places. Fixtures are synthetic but byte-for-byte match the structure
/// of a real capture from 2026-07-05.
final class GetlistParserTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext) else {
            throw XCTSkip("Fixture missing from test bundle.")
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func testExtractsGetlistPathFromListPage() throws {
        let html = try fixture("listpage-snippet", "html")
        let path = GoogleSharedListSource.extractGetlistPath(fromHTML: html)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasPrefix("entitylist/getlist?"))
        XCTAssertTrue(path!.contains("&pb="), "HTML-escaped &amp; must be unescaped")
        XCTAssertFalse(path!.contains("&amp;"))
    }

    func testParsesGetlistResponse() throws {
        let body = try fixture("getlist-response", "txt")
        let places = GoogleSharedListSource.parsePlaces(fromHTML: body)
        XCTAssertEqual(places.count, 6)

        let first = places.first { $0.name == "測試豆漿店" }
        XCTAssertNotNil(first, "local-script names must survive parsing")
        XCTAssertEqual(first?.latitude ?? 0, 25.0526812, accuracy: 0.0001)
        XCTAssertEqual(first?.longitude ?? 0, 121.5344486, accuracy: 0.0001)
        XCTAssertEqual(first?.cid, "1234567890123456789")

        XCTAssertTrue(places.contains { $0.name == "てすと食堂" })
        XCTAssertTrue(places.contains { $0.name == "Cafe & Bar 測試" }, "JS \\u escapes must decode")

        let noID = places.first { $0.name == "無編號小吃店" }
        XCTAssertNotNil(noID)
        XCTAssertNil(noID?.cid, "entry without an id pair gets no cid (never a neighbor's)")
    }

    func testNoStructuralGarbageInNames() throws {
        let body = try fixture("getlist-response", "txt")
        let places = GoogleSharedListSource.parsePlaces(fromHTML: body)
        for place in places {
            XCTAssertFalse(place.name.contains("["), "garbage name: \(place.name)")
            XCTAssertFalse(place.name.contains("null,"), "garbage name: \(place.name)")
            XCTAssertFalse(place.name.contains("\n"))
        }
    }

    func testCidsAreUniquePerPlace() throws {
        let body = try fixture("getlist-response", "txt")
        let places = GoogleSharedListSource.parsePlaces(fromHTML: body)
        let cids = places.compactMap(\.cid)
        XCTAssertEqual(cids.count, Set(cids).count,
                       "a duplicated cid means a window captured a neighbor's id — that opens the wrong restaurant")
    }
}
