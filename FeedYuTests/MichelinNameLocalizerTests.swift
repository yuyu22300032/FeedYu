import XCTest
@testable import FeedYu

@MainActor
final class MichelinNameLocalizerTests: XCTestCase {
    func testParseTitleName() {
        XCTAssertEqual(MichelinNameLocalizer.parseTitleName(
            fromHTML: "<head><title>頤宮 – Taipei - a MICHELIN Guide Restaurant</title></head>"), "頤宮")
        XCTAssertEqual(MichelinNameLocalizer.parseTitleName(
            fromHTML: "<title>青空／Harutaka - 東京 - ミシュランガイドレストラン</title>"), "青空／Harutaka")
        XCTAssertNil(MichelinNameLocalizer.parseTitleName(fromHTML: "<title>MICHELIN Guide</title>"))
        XCTAssertNil(MichelinNameLocalizer.parseTitleName(fromHTML: "no title here"))
    }

    func testEditionURL() {
        let en = URL(string: "https://guide.michelin.com/en/taipei-region/taipei/restaurant/le-palais")!
        XCTAssertEqual(MichelinNameLocalizer.editionURL(for: en, editionKey: "zh_TW")?.absoluteString,
                       "https://guide.michelin.com/tw/zh_TW/taipei-region/taipei/restaurant/le-palais")
        XCTAssertEqual(MichelinNameLocalizer.editionURL(for: en, editionKey: "ja")?.absoluteString,
                       "https://guide.michelin.com/jp/ja/taipei-region/taipei/restaurant/le-palais")
        XCTAssertNil(MichelinNameLocalizer.editionURL(for: URL(string: "https://example.com/x")!, editionKey: "ja"))
    }

    func testLocalEditionKeyFromAddress() {
        var r = Restaurant(name: "X")
        r.address = "6F, 8-3-1 Ginza, Chuo-ku, Tokyo, 104-0061, JPN"
        XCTAssertEqual(r.michelinLocalEditionKey, "ja")
        r.address = "17F, 3, Section 1, Chengde Road, Datong District, Taipei, 103, TWN"
        XCTAssertEqual(r.michelinLocalEditionKey, "zh_TW")
        r.address = "12 Rue de Test, Paris, France"
        XCTAssertNil(r.michelinLocalEditionKey)
    }

    func testDisplayNamePreference() {
        var r = Restaurant(name: "Le Palais")
        r.michelinAward = .threeStars
        r.address = "Taipei, TWN"
        r.localizedNames = ["zh_TW": "頤宮"]
        XCTAssertEqual(r.displayName(nameLanguage: "local"), "頤宮")
        XCTAssertEqual(r.displayName(nameLanguage: "zh"), "頤宮")
        XCTAssertEqual(r.displayName(nameLanguage: "en"), "Le Palais")
        XCTAssertEqual(r.displayName(nameLanguage: "ja"), "Le Palais", "no ja name cached → fallback")
    }
}
