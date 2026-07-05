import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Suggestions open in Google Maps so the user confirms open hours and live
/// traffic there (deliberate decision — the app has no Places API key).
enum GoogleMapsOpener {
    static func url(for restaurant: Restaurant) -> URL {
        // Prefer the stored per-place URL — opens the exact place page.
        if let stored = restaurant.googleMapsURL {
            return stored
        }

        let query = [restaurant.name, restaurant.address ?? ""]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        #if canImport(UIKit)
        // Google Maps app scheme, if installed (declared in LSApplicationQueriesSchemes).
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var scheme = "comgooglemaps://?q=\(encoded)"
        if let coordinate = restaurant.coordinate {
            scheme += "&center=\(coordinate.latitude),\(coordinate.longitude)"
        }
        if let schemeURL = URL(string: scheme), UIApplication.shared.canOpenURL(schemeURL) {
            return schemeURL
        }
        #endif

        var components = URLComponents(string: "https://www.google.com/maps/search/")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: query),
        ]
        return components.url!
    }
}
