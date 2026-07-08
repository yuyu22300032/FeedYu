import Foundation

struct SharedListConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var urlString: String
    var kind: ListKind = .wantToGo
    var label = ""
    var isEnabled = true             // feeds the Tonight tab
    var isEnabledForUberEats = true  // feeds the Uber Eats tab (independent)

    var sourceID: String { "sharedList-\(id.uuidString)" }

    init(urlString: String) {
        self.urlString = urlString
    }

    // Custom decoding: configs persisted before isEnabled /
    // isEnabledForUberEats existed must keep decoding (a synthesized
    // decoder would fail on the missing key and silently drop every saved
    // list). A missing Uber flag inherits the Tonight toggle — that was
    // the old single-toggle behavior.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        urlString = try container.decode(String.self, forKey: .urlString)
        kind = try container.decodeIfPresent(ListKind.self, forKey: .kind) ?? .wantToGo
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isEnabledForUberEats = try container.decodeIfPresent(Bool.self, forKey: .isEnabledForUberEats) ?? isEnabled
    }
}

/// Scrapes a *shared* Google Maps list link (https://maps.app.goo.gl/…).
/// THIS IS THE FRAGILE COMPONENT — Google can change the page format at any
/// time. By design it can only fail its own sync: it never crashes (tolerant
/// scanning, no strict JSON), and failures surface as per-source status in
/// Settings while the app keeps serving the local store.
final class GoogleSharedListSource: RestaurantDataSource {
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Ask Google for the page in the device's language so scraped place
    /// names come back in the local script (繁體中文, 日本語, …).
    static var acceptLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred == "en" ? "en" : "\(preferred),en;q=0.5"
    }

    let config: SharedListConfig

    init(config: SharedListConfig) {
        self.config = config
    }

    var id: String { config.sourceID }

    var displayName: String {
        config.label.isEmpty ? String(localized: "Shared list") : config.label
    }

    func fetch() async throws -> [Restaurant] {
        let trimmed = config.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http") else {
            throw SourceError.badURL(config.urlString)
        }
        // Bare maps.app.goo.gl links serve a JS interstitial to browser UAs;
        // _imcp=1 makes them redirect straight to the real list page.
        if url.host?.hasSuffix("goo.gl") == true, url.query?.contains("_imcp") != true {
            let joiner = url.query == nil ? "?" : "&"
            url = URL(string: url.absoluteString + joiner + "_imcp=1") ?? url
        }
        let html = try await Self.getText(from: url)

        // Old inline format first, then the current two-step format: the page
        // embeds a tokenized entitylist/getlist XHR URL that returns the list
        // (with names in the Accept-Language script).
        var places = Self.parsePlaces(fromHTML: html)
        if places.isEmpty,
           let getlistPath = Self.extractGetlistPath(fromHTML: html),
           let getlistURL = URL(string: "https://www.google.com/maps/preview/" + getlistPath) {
            let body = try await Self.getText(from: getlistURL)
            places = Self.parsePlaces(fromHTML: body)
        }
        guard !places.isEmpty else {
            throw SourceError.parseFailed(String(localized: "No places found in the page — Google may have changed the format, or the list is empty/not public."))
        }
        return places.map { place in
            var restaurant = Restaurant(name: place.name)
            restaurant.latitude = place.latitude
            restaurant.longitude = place.longitude
            restaurant.lists = [config.kind]
            if let cid = place.cid {
                // Same URL format Google Takeout uses — opens the exact place.
                restaurant.googleMapsURL = URL(string: "https://maps.google.com/?cid=\(cid)")
            } else if let ftid = place.ftid {
                restaurant.googleMapsURL = URL(string: "https://maps.google.com/?ftid=\(ftid)")
            }
            return restaurant
        }
    }

    private static func getText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourceError.httpStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds the tokenized list-contents XHR path in the page HTML.
    static func extractGetlistPath(fromHTML html: String) -> String? {
        guard let range = html.range(of: #"entitylist/getlist\?[^"\\ ]+"#, options: .regularExpression) else {
            return nil
        }
        return String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Parser (pure function, unit-tested against a saved fixture)

    struct ParsedPlace: Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
        var ftid: String?
        var cid: String?
    }

    /// Tolerant scan of the `window.APP_INITIALIZATION_STATE = [[[…` JS blob:
    /// finds `[null,null,<lat>,<lng>]` coordinate pairs and takes the first
    /// plausible name string (plus any `0x…:0x…` ftid) in the text right after
    /// each one. Never throws; returns [] when nothing matches.
    static func parsePlaces(fromHTML html: String) -> [ParsedPlace] {
        var region = html
        if let marker = html.range(of: "APP_INITIALIZATION_STATE") {
            region = String(html[marker.lowerBound...])
        }

        guard let coordinateRegex = try? NSRegularExpression(
            pattern: #"\[null,null,(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)\]"#) else { return [] }
        let ftidRegex = try? NSRegularExpression(pattern: #""(0x[0-9a-fA-F]+:0x[0-9a-fA-F]+)""#)
        // getlist responses carry the place id as a decimal pair
        // ["<tile>","<cid>"]; the second value is the ?cid= for Google Maps.
        let cidPairRegex = try? NSRegularExpression(pattern: #"\["(\d{8,25})","(\d{8,25})"\]"#)
        let stringRegex = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)+)""#)

        let nsRegion = region as NSString
        let matches = coordinateRegex.matches(in: region, range: NSRange(location: 0, length: nsRegion.length))

        var places: [ParsedPlace] = []
        var seenCoordinates: Set<String> = []
        var seenNames: Set<String> = []

        for match in matches {
            guard let latitude = Double(nsRegion.substring(with: match.range(at: 1))),
                  let longitude = Double(nsRegion.substring(with: match.range(at: 2))),
                  abs(latitude) <= 90, abs(longitude) <= 180,
                  latitude != 0 || longitude != 0 else { continue }

            let coordinateKey = "\(String(format: "%.4f", latitude)),\(String(format: "%.4f", longitude))"
            guard !seenCoordinates.contains(coordinateKey) else { continue }

            let windowStart = match.range.location + match.range.length
            let windowLength = min(800, nsRegion.length - windowStart)
            guard windowLength > 0 else { continue }
            let window = NSRange(location: windowStart, length: windowLength)

            var ftid: String?
            if let ftidMatch = ftidRegex?.firstMatch(in: region, range: window) {
                ftid = nsRegion.substring(with: ftidMatch.range(at: 1))
            }

            // The place's own id pair sits immediately after the coordinates;
            // pairs further out belong to neighboring entries, so a wrong cid
            // would open the wrong restaurant — better none than wrong.
            var cid: String?
            let cidWindow = NSRange(location: windowStart, length: min(70, nsRegion.length - windowStart))
            if let cidMatch = cidPairRegex?.firstMatch(in: region, range: cidWindow),
               cidMatch.range.location <= windowStart + 3 {
                cid = nsRegion.substring(with: cidMatch.range(at: 2))
            }

            var name: String?
            for stringMatch in stringRegex?.matches(in: region, range: window) ?? [] {
                let raw = nsRegion.substring(with: stringMatch.range(at: 1))
                let decoded = decodeJSStringEscapes(raw)
                if isPlausibleName(decoded) {
                    name = decoded
                    break
                }
            }

            guard var name, !seenNames.contains(name) else { continue }
            name = name.components(separatedBy: .newlines).joined(separator: " ")
            seenCoordinates.insert(coordinateKey)
            seenNames.insert(name)
            places.append(ParsedPlace(name: name, latitude: latitude, longitude: longitude, ftid: ftid, cid: cid))
        }
        return places
    }

    static func isPlausibleName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 120 else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http") || lowered.hasPrefix("//") || lowered.hasPrefix("/") { return false }
        if lowered.hasPrefix("0x") || lowered.hasPrefix("chij") { return false }
        if lowered.contains("googleusercontent") || lowered.contains("gstatic") || lowered.contains(".com/") { return false }
        // Structural JSON fragments that leaked into a string capture.
        if trimmed.contains(where: { "[]{}".contains($0) }) { return false }
        let withoutJSONNoise = lowered
            .replacingOccurrences(of: "null", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;-_ 0123456789"))
        if withoutJSONNoise.isEmpty { return false }
        // Purely numeric/punctuation strings are coordinates or ids, not names.
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.,-+ °").contains($0) }) { return false }
        // Locale/currency codes and similar short ALL-CAPS tokens.
        if trimmed.count <= 3, trimmed == trimmed.uppercased(), trimmed.allSatisfy(\.isLetter) { return false }
        return true
    }

    /// Decodes JS string escapes (\", \\, \uXXXX…) by round-tripping through
    /// the JSON parser; falls back to the raw text.
    static func decodeJSStringEscapes(_ raw: String) -> String {
        let jsonFragment = "\"\(raw)\""
        if let data = jsonFragment.data(using: .utf8),
           let decoded = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String {
            return decoded
        }
        return raw
    }
}
