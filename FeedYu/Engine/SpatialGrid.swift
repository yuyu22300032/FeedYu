import Foundation
import CoreLocation

/// Layered spatial index over restaurants with coordinates. Cells are
/// lat/lng-degree squares at three resolutions (~5.5 km, ~22 km, ~88 km at
/// the equator); a radius query picks the layer whose cells fit the radius,
/// scans the small neighborhood of cells around the origin, then
/// exact-filters by distance. Built once per suggestion session, it turns
/// the per-refresh O(all candidates) distance scan into O(nearby).
/// (No antimeridian handling — a query straddling ±180° longitude misses the
/// far side. Acceptable for restaurant search.)
struct SpatialGrid {
    /// Cell sizes in degrees, finest first.
    static let layerCellDegrees: [Double] = [0.05, 0.2, 0.8]

    private struct Key: Hashable {
        let layer: Int
        let x: Int
        let y: Int
    }

    private var cells: [Key: [Int]] = [:]
    private let restaurants: [Restaurant]

    init(_ restaurants: [Restaurant]) {
        self.restaurants = restaurants
        for (index, restaurant) in restaurants.enumerated() {
            guard let coordinate = restaurant.coordinate else { continue }
            for (layer, size) in Self.layerCellDegrees.enumerated() {
                let key = Key(layer: layer,
                              x: Int(floor(coordinate.longitude / size)),
                              y: Int(floor(coordinate.latitude / size)))
                cells[key, default: []].append(index)
            }
        }
    }

    /// All indexed restaurants within `radiusMeters` of `origin`.
    func query(around origin: CLLocation, radiusMeters: Double) -> [Restaurant] {
        let latDegrees = radiusMeters / 111_000
        // Longitude degrees shrink with latitude; widen the x-span to match.
        let cosLat = max(0.2, cos(origin.coordinate.latitude * .pi / 180))
        let lngDegrees = latDegrees / cosLat

        // Finest layer that still covers the radius with a ≤2-cell span.
        var layer = Self.layerCellDegrees.count - 1
        for (candidate, size) in Self.layerCellDegrees.enumerated()
        where max(latDegrees, lngDegrees) <= size * 2 {
            layer = candidate
            break
        }
        let size = Self.layerCellDegrees[layer]
        let spanX = Int(ceil(lngDegrees / size))
        let spanY = Int(ceil(latDegrees / size))
        let centerX = Int(floor(origin.coordinate.longitude / size))
        let centerY = Int(floor(origin.coordinate.latitude / size))

        var result: [Restaurant] = []
        for x in (centerX - spanX)...(centerX + spanX) {
            for y in (centerY - spanY)...(centerY + spanY) {
                guard let indexes = cells[Key(layer: layer, x: x, y: y)] else { continue }
                for index in indexes {
                    if let distance = restaurants[index].distance(from: origin),
                       distance <= radiusMeters {
                        result.append(restaurants[index])
                    }
                }
            }
        }
        return result
    }
}
