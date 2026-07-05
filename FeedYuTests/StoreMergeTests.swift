import XCTest
@testable import FeedYu

@MainActor
final class RestaurantStoreMergeTests: XCTestCase {
    private func makeStore() -> RestaurantStore { RestaurantStore() }

    func testMergesSamePlaceFromTwoSourcesWithin150m() {
        let store = makeStore()
        var fromTakeout = Restaurant(name: "Sushi Saitō") // diacritic variant
        fromTakeout.latitude = 35.6586
        fromTakeout.longitude = 139.7454
        fromTakeout.lists = [.starred]
        store.apply([fromTakeout], sourceID: "takeout-starred")

        var fromMichelin = Restaurant(name: "Sushi Saito")
        fromMichelin.latitude = 35.6590 // ~45 m away
        fromMichelin.longitude = 139.7452
        fromMichelin.michelinAward = .threeStars
        fromMichelin.priceBand = 4
        store.apply([fromMichelin], sourceID: "michelin")

        XCTAssertEqual(store.restaurants.count, 1)
        let merged = store.restaurants[0]
        XCTAssertEqual(merged.lists, [.starred])
        XCTAssertEqual(merged.michelinAward, .threeStars)
        XCTAssertEqual(merged.priceBand, 4)
        XCTAssertNotNil(merged.lastSeenInSourceAt["takeout-starred"])
        XCTAssertNotNil(merged.lastSeenInSourceAt["michelin"])
    }

    func testSameNameFarApartStaysSeparate() {
        let store = makeStore()
        var tokyo = Restaurant(name: "Le Bistro")
        tokyo.latitude = 35.68; tokyo.longitude = 139.76
        var paris = Restaurant(name: "Le Bistro")
        paris.latitude = 48.85; paris.longitude = 2.35
        store.apply([tokyo], sourceID: "a")
        store.apply([paris], sourceID: "b")
        XCTAssertEqual(store.restaurants.count, 2)
    }

    func testNoCoordinateIncomingMatchesByUniqueName() {
        let store = makeStore()
        var existing = Restaurant(name: "Chez Test")
        existing.latitude = 48.85; existing.longitude = 2.35
        existing.lists = [.wantToGo]
        store.apply([existing], sourceID: "scrape")

        let incoming = Restaurant(name: "Chez Test", lists: [.custom])
        store.apply([incoming], sourceID: "takeout-csv-list")
        XCTAssertEqual(store.restaurants.count, 1)
        XCTAssertEqual(store.restaurants[0].lists, [.wantToGo, .custom])
    }

    func testSourceDroppingPlaceDoesNotDeleteIt() {
        let store = makeStore()
        var place = Restaurant(name: "Keeper")
        place.latitude = 1; place.longitude = 1
        store.apply([place], sourceID: "scrape")
        store.apply([], sourceID: "scrape") // list now empty upstream
        XCTAssertEqual(store.restaurants.count, 1)
    }

    func testHiddenFlagSurvivesResync() {
        let store = makeStore()
        var place = Restaurant(name: "Hide Me")
        place.latitude = 1; place.longitude = 1
        store.apply([place], sourceID: "scrape")
        store.setHidden(true, id: store.restaurants[0].id)
        store.apply([place], sourceID: "scrape")
        XCTAssertEqual(store.restaurants.count, 1)
        XCTAssertTrue(store.restaurants[0].isHidden)
    }
}
