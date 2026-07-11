import XCTest
@testable import FeedYu

final class RestaurantStorePersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testValidStoreFileDecodesAndStaysPut() throws {
        let url = directory.appendingPathComponent("store.json")
        var place = Restaurant(name: "Keeper")
        place.latitude = 25; place.longitude = 121
        let snapshot = RestaurantStore.Snapshot(restaurants: [place], syncStatuses: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url)

        let loaded = RestaurantStore.loadSnapshot(from: url)
        XCTAssertEqual(loaded?.restaurants.first?.name, "Keeper")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    func testCorruptStoreFileIsSetAsideNotLeftForOverwrite() throws {
        // A store file that exists but fails to decode is the user's ONLY
        // copy of their data — the next debounced save would overwrite it.
        // It must be moved aside (recoverable via container surgery), not
        // merely ignored.
        let url = directory.appendingPathComponent("store.json")
        let garbage = Data("{ not json ".utf8)
        try garbage.write(to: url)

        XCTAssertNil(RestaurantStore.loadSnapshot(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the corrupt file must not stay where the next save lands")
        let corrupt = url.appendingPathExtension("corrupt")
        XCTAssertEqual(try Data(contentsOf: corrupt), garbage,
                       "the set-aside copy preserves the original bytes")
    }

    func testMissingStoreFileIsJustEmpty() {
        let url = directory.appendingPathComponent("store.json")
        XCTAssertNil(RestaurantStore.loadSnapshot(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
                       "a first launch has nothing to set aside")
    }
}
