import XCTest
import CoreLocation
@testable import FeedYu

final class SpatialGridTests: XCTestCase {
    private func place(_ name: String, lat: Double, lng: Double?) -> Restaurant {
        var r = Restaurant(name: name)
        r.latitude = lat
        r.longitude = lng
        return r
    }

    func testQueryReturnsOnlyPlacesWithinRadius() {
        let origin = CLLocation(latitude: 25.0330, longitude: 121.5654) // Taipei
        let grid = SpatialGrid([
            place("near", lat: 25.04, lng: 121.56),          // ~1 km
            place("edge-city", lat: 25.10, lng: 121.50),     // ~10 km
            place("kaohsiung", lat: 22.63, lng: 120.30),     // ~300 km
        ])
        let names = grid.query(around: origin, radiusMeters: 40_000).map(\.name).sorted()
        XCTAssertEqual(names, ["edge-city", "near"])
    }

    func testMatchesBruteForceAcrossRadii() {
        // Deterministic pseudo-grid of places around Tokyo; grid results must
        // equal a plain distance filter at every layer's scale.
        let origin = CLLocation(latitude: 35.6812, longitude: 139.7671)
        var places: [Restaurant] = []
        for i in 0..<20 {
            for j in 0..<20 {
                places.append(place("p\(i)-\(j)",
                                    lat: 35.0 + Double(i) * 0.09,
                                    lng: 139.0 + Double(j) * 0.11))
            }
        }
        let grid = SpatialGrid(places)
        for radius in [3_000.0, 20_000.0, 80_000.0, 200_000.0] {
            let expected = Set(places.compactMap { p -> String? in
                guard let d = p.distance(from: origin), d <= radius else { return nil }
                return p.name
            })
            let actual = Set(grid.query(around: origin, radiusMeters: radius).map(\.name))
            XCTAssertEqual(actual, expected, "radius \(radius)")
        }
    }

    func testHighLatitudeLongitudeSpan() {
        // At 64°N a degree of longitude is ~49 km — the query must widen its
        // cell span instead of missing places due east/west.
        let origin = CLLocation(latitude: 64.15, longitude: -21.94) // Reykjavik
        let grid = SpatialGrid([
            place("east-30km", lat: 64.15, lng: -21.33),
        ])
        let names = grid.query(around: origin, radiusMeters: 40_000).map(\.name)
        XCTAssertEqual(names, ["east-30km"])
    }

    func testPlacesWithoutCoordinatesAreExcluded() {
        let origin = CLLocation(latitude: 25.0, longitude: 121.5)
        let grid = SpatialGrid([
            place("no-coords", lat: 25.0, lng: nil),
            place("zero-island", lat: 0, lng: 0), // (0,0) treated as missing
        ])
        XCTAssertTrue(grid.query(around: origin, radiusMeters: 50_000).isEmpty)
    }
}
