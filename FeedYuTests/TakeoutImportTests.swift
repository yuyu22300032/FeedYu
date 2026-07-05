import XCTest
@testable import FeedYu

final class TakeoutImportTests: XCTestCase {
    func testParseSavedPlacesGeoJSON() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"geometry":{"coordinates":[139.7454,35.6586],"type":"Point"},
           "properties":{"date":"2025-01-01T00:00:00Z",
                         "google_maps_url":"http://maps.google.com/?cid=123",
                         "location":{"address":"Tokyo","country_code":"JP","name":"Sushi Saito"}},
           "type":"Feature"},
          {"geometry":{"coordinates":[0,0],"type":"Point"},
           "properties":{"Title":"No Coords Place","google_maps_url":"http://maps.google.com/?cid=456"},
           "type":"Feature"}
        ]}
        """
        let restaurants = try TakeoutImportSource.parseSavedPlaces(Data(json.utf8))
        XCTAssertEqual(restaurants.count, 2)
        let saito = restaurants[0]
        XCTAssertEqual(saito.name, "Sushi Saito")
        XCTAssertEqual(saito.lists, [.starred])
        XCTAssertEqual(saito.latitude ?? 0, 35.6586, accuracy: 0.0001)
        XCTAssertEqual(saito.address, "Tokyo")
        // [0,0] coordinates are treated as missing.
        XCTAssertNil(restaurants[1].coordinate)
        XCTAssertEqual(restaurants[1].name, "No Coords Place")
    }

    func testParseSavedPlacesRejectsGarbage() {
        XCTAssertThrowsError(try TakeoutImportSource.parseSavedPlaces(Data("not json".utf8)))
        XCTAssertThrowsError(try TakeoutImportSource.parseSavedPlaces(Data("{}".utf8)))
    }

    func testParseListCSV() throws {
        let csv = """
        Title,Note,URL
        "Bar, Etc.",Great bar,https://maps.app.goo.gl/abc
        Chez Test,,https://maps.app.goo.gl/def
        """
        let restaurants = try TakeoutImportSource.parseListCSV(Data(csv.utf8), kind: .wantToGo)
        XCTAssertEqual(restaurants.count, 2)
        XCTAssertEqual(restaurants[0].name, "Bar, Etc.")
        XCTAssertEqual(restaurants[0].lists, [.wantToGo])
        XCTAssertEqual(restaurants[0].googleMapsURL?.absoluteString, "https://maps.app.goo.gl/abc")
        XCTAssertNil(restaurants[0].coordinate)
    }

    func testExtractCoordinatePrefersPlacePin() {
        let text = "https://www.google.com/maps/place/X/@35.6595,139.7005,17z/data=!3d35.6586!4d139.7454"
        let coordinate = TakeoutImportSource.extractCoordinate(fromText: text)
        XCTAssertEqual(coordinate?.latitude ?? 0, 35.6586, accuracy: 0.0001)
        XCTAssertEqual(coordinate?.longitude ?? 0, 139.7454, accuracy: 0.0001)
    }

    func testExtractCoordinateFallsBackToViewport() {
        let text = "https://www.google.com/maps/place/X/@35.6595,139.7005,17z"
        let coordinate = TakeoutImportSource.extractCoordinate(fromText: text)
        XCTAssertEqual(coordinate?.latitude ?? 0, 35.6595, accuracy: 0.0001)
    }

    func testExtractCoordinateNilOnJunk() {
        XCTAssertNil(TakeoutImportSource.extractCoordinate(fromText: "no coordinates here"))
    }
}
