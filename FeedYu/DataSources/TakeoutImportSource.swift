import Foundation
import CoreLocation

/// Google Takeout import — the reliable manual fallback, and the only route
/// for Starred places (Google doesn't allow sharing the starred list).
///
/// - `Saved Places.json` (Starred): GeoJSON with coordinates. Easy.
/// - `Saved/<ListName>.csv` (Want to go / custom): Title,Note,URL — no
///   coordinates. Resolved best-effort: place-URL scrape → CLGeocoder → none.
final class TakeoutImportSource: RestaurantDataSource {
    enum Payload {
        case savedPlacesJSON(Data)
        case listCSV(Data, kind: ListKind, listName: String)
    }

    let payload: Payload

    init(payload: Payload) {
        self.payload = payload
    }

    var id: String {
        switch payload {
        case .savedPlacesJSON: return "takeout-starred"
        case .listCSV(_, _, let listName): return "takeout-csv-\(Restaurant.normalize(listName))"
        }
    }

    var displayName: String {
        switch payload {
        case .savedPlacesJSON: return String(localized: "Takeout: Saved Places (Starred)")
        case .listCSV(_, _, let listName): return String(localized: "Takeout: \(listName)")
        }
    }

    func fetch() async throws -> [Restaurant] {
        switch payload {
        case .savedPlacesJSON(let data):
            return try Self.parseSavedPlaces(data)
        case .listCSV(let data, let kind, _):
            let parsed = try Self.parseListCSV(data, kind: kind)
            return await Self.resolvingCoordinates(parsed)
        }
    }

    // MARK: - Saved Places.json (GeoJSON)

    static func parseSavedPlaces(_ data: Data) throws -> [Restaurant] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [[String: Any]] else {
            throw SourceError.parseFailed(String(localized: "Not a Saved Places GeoJSON file."))
        }
        var result: [Restaurant] = []
        for feature in features {
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let locationInfo = properties["location"] as? [String: Any]
            let name = (locationInfo?["name"] as? String)
                ?? (properties["Title"] as? String)
                ?? (properties["name"] as? String)
            guard let name, !name.isEmpty else { continue }

            var restaurant = Restaurant(name: name)
            restaurant.lists = [.starred]
            if let geometry = feature["geometry"] as? [String: Any],
               let coordinates = geometry["coordinates"] as? [Any],
               coordinates.count >= 2,
               let longitude = (coordinates[0] as? NSNumber)?.doubleValue,
               let latitude = (coordinates[1] as? NSNumber)?.doubleValue,
               latitude != 0 || longitude != 0 {
                restaurant.latitude = latitude
                restaurant.longitude = longitude
            }
            restaurant.address = locationInfo?["address"] as? String
            if let urlString = properties["google_maps_url"] as? String {
                restaurant.googleMapsURL = URL(string: urlString)
            }
            result.append(restaurant)
        }
        guard !result.isEmpty else {
            throw SourceError.parseFailed(String(localized: "No places found in the file."))
        }
        return result
    }

    // MARK: - List CSV (Title,Note,URL)

    static func parseListCSV(_ data: Data, kind: ListKind) throws -> [Restaurant] {
        let text = String(decoding: data, as: UTF8.self)
        let records = CSVParser.parseRecords(text)
        var result: [Restaurant] = []
        for record in records {
            let title = value(in: record, key: "title")
            guard let title, !title.isEmpty else { continue }
            var restaurant = Restaurant(name: title)
            restaurant.lists = [kind]
            if let urlString = value(in: record, key: "url"), let url = URL(string: urlString) {
                restaurant.googleMapsURL = url
            }
            if let note = value(in: record, key: "note"), !note.isEmpty {
                restaurant.summary = note
            }
            result.append(restaurant)
        }
        guard !result.isEmpty else {
            throw SourceError.parseFailed(String(localized: "No rows with a Title column found — is this a Takeout list CSV?"))
        }
        return result
    }

    private static func value(in record: [String: String], key: String) -> String? {
        for (recordKey, recordValue) in record where recordKey.lowercased() == key {
            return recordValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Coordinate resolution

    /// Best-effort, sequential (geocoder and Google both dislike bursts).
    /// Order: (a) scrape the place URL, (b) CLGeocoder on the title,
    /// (c) leave without coordinates (still listed, excluded from distance filters).
    static func resolvingCoordinates(_ restaurants: [Restaurant]) async -> [Restaurant] {
        var result: [Restaurant] = []
        let geocoder = CLGeocoder()
        for var restaurant in restaurants {
            if restaurant.coordinate == nil, let url = restaurant.googleMapsURL {
                if let coordinate = await fetchCoordinate(fromPlaceURL: url) {
                    restaurant.latitude = coordinate.latitude
                    restaurant.longitude = coordinate.longitude
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if restaurant.coordinate == nil {
                let query = [restaurant.name, restaurant.address ?? ""]
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if let placemark = try? await geocoder.geocodeAddressString(query).first,
                   let location = placemark.location {
                    restaurant.latitude = location.coordinate.latitude
                    restaurant.longitude = location.coordinate.longitude
                    if restaurant.address == nil {
                        restaurant.address = placemark.name
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            result.append(restaurant)
        }
        return result
    }

    static func fetchCoordinate(fromPlaceURL url: URL) async -> CLLocationCoordinate2D? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(GoogleSharedListSource.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        var haystack = response.url?.absoluteString ?? ""
        haystack += String(decoding: data.prefix(400_000), as: UTF8.self)
        return extractCoordinate(fromText: haystack)
    }

    /// `!3d<lat>!4d<lng>` is the place pin (preferred); `@<lat>,<lng>` is the
    /// map viewport (fallback).
    static func extractCoordinate(fromText text: String) -> CLLocationCoordinate2D? {
        if let match = text.firstMatch(of: #/!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)/#),
           let latitude = Double(match.1), let longitude = Double(match.2),
           abs(latitude) <= 90, abs(longitude) <= 180 {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        if let match = text.firstMatch(of: #/@(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)/#),
           let latitude = Double(match.1), let longitude = Double(match.2),
           abs(latitude) <= 90, abs(longitude) <= 180 {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return nil
    }
}
