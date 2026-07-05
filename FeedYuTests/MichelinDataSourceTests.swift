import XCTest
@testable import FeedYu

final class MichelinDataSourceTests: XCTestCase {
    private let sampleCSV = """
    Name,Address,Location,Price,Cuisine,Longitude,Latitude,Url,Award,Description
    Le Test,"1 Rue de Test, Paris",Paris,€€€,French,2.3522,48.8566,https://guide.michelin.com/le-test,1 Star,"A test, with a comma."
    Bib Place,Somewhere,Tokyo,¥¥,Japanese,139.6917,35.6895,https://guide.michelin.com/bib,Bib Gourmand,Cozy.
    Skipped Place,Nowhere,London,££,British,-0.1276,51.5074,https://guide.michelin.com/skip,Selected Restaurants,Not starred.
    Three Star,Fancy St,New York,$$$$,American,-74.0060,40.7128,https://guide.michelin.com/three,3 Stars,Fancy.
    """

    func testParsesAllAwardsIncludingSelected() {
        let restaurants = MichelinDataSource.parseCSV(sampleCSV)
        XCTAssertEqual(restaurants.count, 4)
        let selected = restaurants.first { $0.name == "Skipped Place" }
        XCTAssertEqual(selected?.michelinAward, .selected)
    }

    func testHistoryOverlay() {
        let current = MichelinDataSource.parseCSV(sampleCSV)
        let history = """
        Name,Address,Location,Price,Cuisine,Longitude,Latitude,Url,Award,Description,Years,Current
        Le Test,,,,,2.3522,48.8566,,,,2022–2026,1
        Gone Place,"9 Rue X, Paris",Paris,€€,French,2.3600,48.8600,https://guide.michelin.com/gone,1 Star,Closed since.,2022–2024,0
        """
        let overlaid = MichelinDataSource.applyHistoryOverlay(to: current, historyCSV: history)
        XCTAssertEqual(overlaid.count, current.count + 1)
        let leTest = overlaid.first { $0.name == "Le Test" }
        XCTAssertEqual(leTest?.michelinYears, "2022–2026")
        XCTAssertNil(leTest?.michelinFormer)
        let gone = overlaid.first { $0.name == "Gone Place" }
        XCTAssertEqual(gone?.michelinFormer, true)
        XCTAssertEqual(gone?.michelinYears, "2022–2024")
        XCTAssertEqual(gone?.michelinAward, .oneStar)
        XCTAssertEqual(gone?.priceBand, 2)
    }

    func testAwardAndLocalCurrencyPriceBand() {
        let restaurants = MichelinDataSource.parseCSV(sampleCSV)
        let leTest = restaurants.first { $0.name == "Le Test" }
        XCTAssertEqual(leTest?.michelinAward, .oneStar)
        XCTAssertEqual(leTest?.priceBand, 3) // €€€ → 3
        XCTAssertEqual(leTest?.cuisine, "French")
        XCTAssertEqual(leTest?.latitude ?? 0, 48.8566, accuracy: 0.0001)

        let bib = restaurants.first { $0.name == "Bib Place" }
        XCTAssertEqual(bib?.michelinAward, .bibGourmand)
        XCTAssertEqual(bib?.priceBand, 2) // ¥¥ → 2

        let three = restaurants.first { $0.name == "Three Star" }
        XCTAssertEqual(three?.michelinAward, .threeStars)
        XCTAssertEqual(three?.priceBand, 4)
    }

    func testBundledSnapshotParses() throws {
        let bundle = Bundle(for: RestaurantStore.self)
        guard let url = bundle.url(forResource: "michelin", withExtension: "csv") else {
            throw XCTSkip("Bundled snapshot not visible from the test bundle.")
        }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let restaurants = MichelinDataSource.parseCSV(text)
        XCTAssertGreaterThan(restaurants.count, 18000)
        XCTAssertTrue(restaurants.allSatisfy { $0.michelinAward != nil })
    }

    func testPriceBandClamping() {
        XCTAssertNil(MichelinDataSource.priceBand(from: ""))
        XCTAssertEqual(MichelinDataSource.priceBand(from: "$"), 1)
        XCTAssertEqual(MichelinDataSource.priceBand(from: "$$$$$"), 4)
    }
}
