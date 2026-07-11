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

    func testNoCoordinateIncomingNeverMergesIntoMichelinRow() {
        // A Takeout CSV row whose URL-scrape and geocode both failed used to
        // merge into ANY unique same-named row — including a Michelin place
        // on the other side of the world; the user's place then inherited
        // the foreign coordinates and silently fell out of every radius.
        let store = makeStore()
        var guide = Restaurant(name: "Saigon")
        guide.latitude = 10.77; guide.longitude = 106.70 // Ho Chi Minh City
        guide.michelinAward = .bibGourmand
        store.apply([guide], sourceID: "michelin")

        let incoming = Restaurant(name: "Saigon", lists: [.custom])
        store.apply([incoming], sourceID: "takeout-csv-list")
        XCTAssertEqual(store.restaurants.count, 2, "appended, not swallowed by the guide row")
        let mine = store.restaurants.first { $0.michelinAward == nil }
        XCTAssertNil(mine?.coordinate, "the user's row keeps waiting for its own coordinates")
    }

    func testNoCoordinateIncomingMergesIntoUserRowDespiteMichelinNamesake() {
        // Uniqueness is judged among user rows only — a same-named guide
        // place elsewhere must not block the legitimate Takeout CSV merge.
        let store = makeStore()
        var guide = Restaurant(name: "Chez Test")
        guide.latitude = 10.77; guide.longitude = 106.70
        guide.michelinAward = .oneStar
        var mine = Restaurant(name: "Chez Test")
        mine.latitude = 48.85; mine.longitude = 2.35
        mine.lists = [.wantToGo]
        store.apply([guide], sourceID: "michelin")
        store.apply([mine], sourceID: "scrape")
        XCTAssertEqual(store.restaurants.count, 2, "far apart — separate rows")

        let incoming = Restaurant(name: "Chez Test", lists: [.custom])
        store.apply([incoming], sourceID: "takeout-csv-list")
        XCTAssertEqual(store.restaurants.count, 2)
        let merged = store.restaurants.first { $0.michelinAward == nil }
        XCTAssertEqual(merged?.lists, [.wantToGo, .custom])
        XCTAssertNotNil(merged?.lastSeenInSourceAt["takeout-csv-list"])
    }

    func testNoCoordinateIncomingMergesIntoUserRowThatAbsorbedGuideRow() {
        // A user's place that merged with its local Michelin row carries
        // the award — it is still a USER row (source stamps say so) and
        // must keep matching its own coordinate-less re-imports.
        // Discriminating by michelinAward appended a coordinate-less
        // ghost duplicate on every re-import.
        let store = makeStore()
        var mine = Restaurant(name: "Den")
        mine.latitude = 35.66; mine.longitude = 139.72
        mine.lists = [.wantToGo]
        store.apply([mine], sourceID: "takeout-csv-list")
        var guide = Restaurant(name: "Den")
        guide.latitude = 35.6601; guide.longitude = 139.7201 // ~15 m away
        guide.michelinAward = .oneStar
        store.apply([guide], sourceID: "michelin")
        XCTAssertEqual(store.restaurants.count, 1, "guide row merged into the user's place")

        let reimport = Restaurant(name: "Den", lists: [.custom])
        store.apply([reimport], sourceID: "takeout-csv-list")
        XCTAssertEqual(store.restaurants.count, 1, "re-import merges — no coordinate-less ghost")
        XCTAssertEqual(store.restaurants[0].michelinAward, .oneStar)
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

    func testNegativeMarkersAreClearedByTheirSuccesses() {
        let store = makeStore()
        var place = Restaurant(name: "Cooldowns")
        place.latitude = 25; place.longitude = 121
        store.apply([place], sourceID: "scrape")
        let id = store.restaurants[0].id

        store.setUberEatsNotFound(id: id)
        XCTAssertNotNil(store.restaurants[0].uberEatsNotFoundAt)
        store.setUberEatsURL(id: id, url: URL(string: "https://www.ubereats.com/store-browse-uuid/x")!)
        XCTAssertNil(store.restaurants[0].uberEatsNotFoundAt, "a verified store link ends the cooldown")

        store.setMapsNoMatch(id: id, searchName: "Cooldowns")
        XCTAssertEqual(store.restaurants[0].mapsNoMatchName, "Cooldowns")
        store.setGoogleMapsURL(id: id, url: URL(string: "https://maps.google.com/?cid=1")!)
        XCTAssertNil(store.restaurants[0].mapsNoMatchAt, "a resolved cid ends the cooldown")
        XCTAssertNil(store.restaurants[0].mapsNoMatchName)
    }

    func testResolvedCidUpgradesStoredSearchURLButNeverExactOne() {
        let store = makeStore()
        var place = Restaurant(name: "Everywhere")
        place.latitude = 25; place.longitude = 121
        place.googleMapsURL = URL(string: "https://www.google.com/maps/search/Everywhere/data=!4m2")
        store.apply([place], sourceID: "takeout-list")
        let id = store.restaurants[0].id
        let cidURL = URL(string: "https://maps.google.com/?cid=42")!

        // Search URL → upgraded to the resolved cid.
        store.setGoogleMapsURL(id: id, url: cidURL)
        XCTAssertEqual(store.restaurants[0].googleMapsURL, cidURL)

        // Exact URL → never clobbered, not even by another exact one.
        store.setGoogleMapsURL(id: id, url: URL(string: "https://maps.google.com/?cid=99")!)
        XCTAssertEqual(store.restaurants[0].googleMapsURL, cidURL)

        // And never downgraded back to a search URL.
        store.setGoogleMapsURL(id: id, url: URL(string: "https://www.google.com/maps/search/x")!)
        XCTAssertEqual(store.restaurants[0].googleMapsURL, cidURL)
    }
}

extension RestaurantStoreMergeTests {
    func testClosedUntilPersistsWithFallbackAndClearsOnOpen() {
        let store = makeStore()
        var place = Restaurant(name: "Afternoon Closed")
        place.latitude = 25; place.longitude = 121
        store.apply([place], sourceID: "scrape")
        let id = store.restaurants[0].id

        // Uber gave a reopen time → persisted verbatim.
        let reopens = Date().addingTimeInterval(3 * 3600)
        store.setUberEatsClosedUntil(id: id, reopens: reopens)
        XCTAssertEqual(store.restaurants[0].uberEatsClosedUntil, reopens)

        // No reopen time from Uber → 10-minute fallback.
        store.clearUberEatsClosedUntil(id: id)
        let before = Date()
        store.setUberEatsClosedUntil(id: id, reopens: nil)
        let until = store.restaurants[0].uberEatsClosedUntil
        XCTAssertNotNil(until)
        let delta = until!.timeIntervalSince(before)
        XCTAssertGreaterThan(delta, 9 * 60, "fallback ≈ 10 minutes out")
        XCTAssertLessThan(delta, 11 * 60)

        // A verified open ends the suppression.
        store.clearUberEatsClosedUntil(id: id)
        XCTAssertNil(store.restaurants[0].uberEatsClosedUntil)
    }
}
