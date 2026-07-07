import XCTest
@testable import FeedYu

@MainActor
final class ListRemovalTests: XCTestCase {
    private func place(_ name: String, sources: [String],
                       manual: Bool = false, award: MichelinAward? = nil) -> Restaurant {
        var r = Restaurant(name: name)
        r.latitude = 25.0
        r.longitude = 121.5
        r.addedManually = manual
        r.michelinAward = award
        for source in sources {
            r.lastSeenInSourceAt[source] = Date()
        }
        return r
    }

    func testRemoveListDeletesExclusivePlacesOnly() {
        let store = RestaurantStore()
        let listA = "sharedList-A"
        let listB = "sharedList-B"
        store.apply([place("only-on-A", sources: [])], sourceID: listA)
        store.apply([place("on-A-and-B", sources: [listB])], sourceID: listA)
        store.apply([place("manual-on-A", sources: [], manual: true)], sourceID: listA)
        store.apply([place("michelin-on-A", sources: ["michelin"], award: .oneStar)], sourceID: listA)
        store.apply([place("only-on-B", sources: [])], sourceID: listB)

        store.removeList(sourceID: listA, otherListSourceIDs: [listB])

        let names = Set(store.restaurants.map(\.name))
        XCTAssertEqual(names, ["on-A-and-B", "manual-on-A", "michelin-on-A", "only-on-B"],
                       "only the place exclusive to list A is deleted")
        // Survivors no longer carry the removed list's stamp.
        for restaurant in store.restaurants {
            XCTAssertNil(restaurant.lastSeenInSourceAt[listA], restaurant.name)
        }
    }

    func testRemoveListIgnoresOrphanStampsFromPreviouslyDeletedLists() {
        let store = RestaurantStore()
        let ghost = "sharedList-deleted-long-ago"
        store.apply([place("orphan-stamped", sources: [ghost])], sourceID: "sharedList-A")
        // ghost is NOT in the registered set → doesn't count as "another list".
        store.removeList(sourceID: "sharedList-A", otherListSourceIDs: [])
        XCTAssertTrue(store.restaurants.isEmpty)
    }

}
