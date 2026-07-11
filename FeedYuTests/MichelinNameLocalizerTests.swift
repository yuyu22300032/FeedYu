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

/// The fill loop's bookkeeping through the REAL run, with the page fetch
/// stubbed (`MichelinNameLocalizer.fetchName` — the etaProvider/runJS
/// seam). Pins gotcha #13: a cancelled run must not record its aborted
/// fetches as failures, or the session-long negative cache silently
/// blocks those names for the rest of the session.
@MainActor
final class MichelinNameLocalizerFlowTests: XCTestCase {
    private var localizer: MichelinNameLocalizer!
    private var store: RestaurantStore!
    private var seeded: Restaurant!

    override func setUp() async throws {
        localizer = MichelinNameLocalizer()
        store = RestaurantStore()
        MichelinNameLocalizer.interFetchDelayNanoseconds = 0
        var r = Restaurant(name: "Le Palais")
        r.address = "Taipei, TWN"
        r.michelinAward = .threeStars
        r.michelinURL = URL(string: "https://guide.michelin.com/en/taipei-region/taipei/restaurant/le-palais")
        store.apply([r], sourceID: "michelin")
        seeded = store.restaurants[0]
    }

    override func tearDown() async throws {
        MichelinNameLocalizer.fetchName = { await MichelinNameLocalizer.livePageName(from: $0) }
        MichelinNameLocalizer.interFetchDelayNanoseconds = 400_000_000
    }

    func testCancelledFillDoesNotPoisonTheNegativeCache() async {
        // Phase 1: a fetch is in flight when the run is cancelled — the
        // real URLSession call then fails "instantly", which is exactly
        // what used to get recorded as a failure (gotcha #13).
        MichelinNameLocalizer.fetchName = { _ in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return nil
        }
        let fill = Task {
            await localizer.fill(restaurants: [seeded], nameLanguage: "local", store: store)
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // let the fetch start
        fill.cancel()
        await fill.value

        // Phase 2: the SAME restaurant gets a fresh attempt this session.
        MichelinNameLocalizer.fetchName = { _ in "頤宮" }
        await localizer.fill(restaurants: [seeded], nameLanguage: "local", store: store)
        XCTAssertEqual(store.restaurant(withID: seeded.id)?.localizedNames?["zh_TW"], "頤宮",
                       "a cancelled attempt must not be negatively cached")
    }

    func testGenuineFailureIsNegativelyCachedForTheSession() async {
        var calls = 0
        MichelinNameLocalizer.fetchName = { _ in calls += 1; return nil }
        await localizer.fill(restaurants: [seeded], nameLanguage: "local", store: store)
        await localizer.fill(restaurants: [seeded], nameLanguage: "local", store: store)
        XCTAssertEqual(calls, 1, "a real failure is skipped for the rest of the session")
    }
}
