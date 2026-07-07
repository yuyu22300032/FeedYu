import Foundation
import CoreLocation

/// Resolves a place's Google Maps cid (the id behind fast, exact
/// `maps.google.com/?cid=` links) from a coordinate-anchored search page.
/// Used for places the list scraper imported without an id — opening them
/// through a search URL works but is slow (the Maps app runs a live
/// search); a resolved cid makes every later open instant.
///
/// Wire format: the search page HTML embeds each result's feature id as
/// `!1s0x<tile>:0x<id>` with its pin at `!3d<lat>!4d<lng>` nearby. The cid
/// is the DECIMAL value of the id half (this is Google's documented
/// "ludocid"). Proximity to our saved coordinates picks the right result —
/// same principle as the Uber Eats matcher, names lie but pins don't.
enum GooglePlaceResolver {
    /// Accept a result only when its pin is this close to our place.
    static let matchRadiusMeters: CLLocationDistance = 150

    static func resolveCid(name: String, coordinate: CLLocationCoordinate2D) async -> String? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let anchor = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        guard let url = URL(string: "https://www.google.com/maps/search/\(encoded)/@\(anchor),17z") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // google.com/maps serves the data-bearing page to desktop UAs.
        request.setValue(GoogleSharedListSource.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GoogleSharedListSource.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false else {
            return nil
        }
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        return extractCid(fromHTML: html, near: coordinate)
    }

    /// Feature ids with a pin within `matchRadiusMeters` of `coordinate`;
    /// nearest wins. Tolerant scan — no assumptions about page structure
    /// beyond the `!1s…` / `!3d…!4d…` tokens appearing per result.
    static func extractCid(fromHTML html: String, near coordinate: CLLocationCoordinate2D) -> String? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (distance: CLLocationDistance, cid: String)?

        for match in html.matches(of: #/0x[0-9a-fA-F]{6,}:0x([0-9a-fA-F]{1,16})/#) {
            // The pin belonging to this feature id sits in the same result
            // blob — scan a window after the id for !3d<lat>!4d<lng>.
            let windowEnd = html.index(match.range.upperBound, offsetBy: 400, limitedBy: html.endIndex) ?? html.endIndex
            let window = html[match.range.upperBound..<windowEnd]
            guard let pin = window.firstMatch(of: #/!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)/#),
                  let latitude = Double(pin.1), let longitude = Double(pin.2),
                  abs(latitude) <= 90, abs(longitude) <= 180 else { continue }
            let distance = target.distance(from: CLLocation(latitude: latitude, longitude: longitude))
            guard distance <= matchRadiusMeters else { continue }
            guard let value = UInt64(String(match.1), radix: 16), value != 0 else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, String(value))
            }
        }
        return best?.cid
    }
}
