import XCTest
@testable import FeedYu

final class ListConfigTests: XCTestCase {
    /// Configs saved before `isEnabled` existed must keep decoding (and come
    /// back enabled) — a decode failure here silently drops every saved list.
    func testSharedListConfigDecodesLegacyJSONWithoutIsEnabled() throws {
        let legacy = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","urlString":"https://maps.app.goo.gl/abc","kind":"wantToGo","label":"Date nights"}]
        """
        let configs = try JSONDecoder().decode([SharedListConfig].self, from: Data(legacy.utf8))
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].label, "Date nights")
        XCTAssertTrue(configs[0].isEnabled)
        XCTAssertEqual(configs[0].sourceID, "sharedList-6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }

    func testSharedListConfigRoundTripsIsEnabled() throws {
        var config = SharedListConfig(urlString: "https://maps.app.goo.gl/x")
        config.isEnabled = false
        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([SharedListConfig].self, from: data)
        XCTAssertFalse(decoded[0].isEnabled)
    }

    func testImportedListConfigDecodesMinimalJSON() throws {
        let json = """
        [{"sourceID":"takeout-starred","label":"Starred"}]
        """
        let configs = try JSONDecoder().decode([ImportedListConfig].self, from: Data(json.utf8))
        XCTAssertEqual(configs[0].kind, .custom)
        XCTAssertTrue(configs[0].isEnabled)
    }

    func testShareInboxFindsURLInSharedText() {
        XCTAssertEqual(
            ShareInbox.firstHTTPURL(in: "Check out my list! https://maps.app.goo.gl/AbC123 shared from Google Maps"),
            "https://maps.app.goo.gl/AbC123"
        )
        XCTAssertNil(ShareInbox.firstHTTPURL(in: "no links here"))
    }
}
