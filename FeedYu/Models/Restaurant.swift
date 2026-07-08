import Foundation
import CoreLocation

enum ListKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case starred
    case wantToGo
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .starred: return String(localized: "Starred")
        case .wantToGo: return String(localized: "Want to go")
        case .custom: return String(localized: "Custom list")
        }
    }

    var systemImage: String {
        switch self {
        case .starred: return "star.fill"
        case .wantToGo: return "flag.fill"
        case .custom: return "list.bullet"
        }
    }
}

enum MichelinAward: String, Codable, CaseIterable, Identifiable {
    case selected      // "Selected Restaurants" — the Plate
    case bibGourmand
    case oneStar
    case twoStars
    case threeStars

    var id: String { rawValue }

    /// Maps the `Award` column of the michelin-my-maps dataset. Returns nil for
    /// "Selected Restaurants" and anything unrecognized.
    init?(datasetValue: String) {
        switch datasetValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "selected restaurants": self = .selected
        case "1 star": self = .oneStar
        case "2 stars": self = .twoStars
        case "3 stars": self = .threeStars
        case "bib gourmand": self = .bibGourmand
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .selected: return String(localized: "Michelin Selected")
        case .bibGourmand: return String(localized: "Bib Gourmand")
        case .oneStar: return String(localized: "1 MICHELIN Star")
        case .twoStars: return String(localized: "2 MICHELIN Stars")
        case .threeStars: return String(localized: "3 MICHELIN Stars")
        }
    }

    var badge: String {
        switch self {
        case .selected: return String(localized: "Selected")
        case .bibGourmand: return String(localized: "Bib Gourmand")
        case .oneStar: return "⭐️"
        case .twoStars: return "⭐️⭐️"
        case .threeStars: return "⭐️⭐️⭐️"
        }
    }
}

struct Restaurant: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double?
    var longitude: Double?
    var address: String?
    var googleMapsURL: URL?
    var michelinURL: URL?
    var lists: Set<ListKind> = []
    var michelinAward: MichelinAward?
    var michelinYears: String?       // e.g. "2022–2024" (from the history overlay)
    var michelinFormer: Bool?        // true = no longer on the current guide
    var localizedNames: [String: String]?  // guide edition key ("zh_TW", "ja") → name
    var priceBand: Int?          // 1–4, i.e. $–$$$$
    var cuisine: String?
    var summary: String?
    var imageURL: URL?           // cover photo, lazily scraped (Optional — store back-compat)
    var uberEatsURL: URL?        // exact store page, captured by the availability check
    var uberEatsNotFoundAt: Date?    // last VERIFIED "not on Uber Eats" (cooldown gate)
    var mapsNoMatchAt: Date?         // last definitive cid-resolution no-match…
    var mapsNoMatchName: String?     // …and the search name it failed under
    var isHidden = false
    var addedManually = false
    var lastSeenInSourceAt: [String: Date] = [:]

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude != 0 || longitude != 0,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation? {
        guard let coordinate else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var priceLabel: String? {
        guard let priceBand else { return nil }
        return String(repeating: "$", count: min(4, max(1, priceBand)))
    }

    var normalizedName: String { Restaurant.normalize(name) }

    /// Dedupe key half: lowercased, diacritics stripped, alphanumerics only.
    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Which guide edition carries this restaurant's local-language name,
    /// based on the ISO3/country hints in the dataset address.
    var michelinLocalEditionKey: String? {
        guard let address else { return nil }
        let a = address.uppercased()
        if a.contains("TWN") || a.contains("TAIWAN") { return "zh_TW" }
        if a.contains("JPN") || a.contains("JAPAN") { return "ja" }
        if a.contains("HONG KONG") || a.contains("HKG") { return "zh_HK" }
        if a.contains("MACAU") || a.contains("MAC,") { return "zh_HK" }
        if a.contains("CHINA") || a.contains("CHN") { return "zh_CN" }
        return nil
    }

    /// preference: "en" | "zh" | "ja" | "local" (Settings → Michelin data).
    func editionKey(preference: String) -> String? {
        switch preference {
        case "zh": return "zh_TW"
        case "ja": return "ja"
        case "local": return michelinLocalEditionKey
        default: return nil
        }
    }

    /// Name to display for Michelin places, honoring the name-language
    /// preference; falls back to the dataset (romanized) name.
    func displayName(nameLanguage: String) -> String {
        guard michelinAward != nil,
              let key = editionKey(preference: nameLanguage),
              let localized = localizedNames?[key], !localized.isEmpty else { return name }
        return localized
    }

    /// Name to use when searching Google Maps around the place's own pin:
    /// the local-market listing name when the localizer has cached one —
    /// Google often can't match the Michelin dataset's romanization near
    /// the anchor (e.g. "Uosho" vs 魚庄) — else the dataset name.
    var googleSearchName: String {
        guard let key = michelinLocalEditionKey,
              let localized = localizedNames?[key], !localized.isEmpty else { return name }
        return localized
    }

    func distance(from origin: CLLocation) -> CLLocationDistance? {
        guard let location else { return nil }
        return origin.distance(from: location)
    }

    /// Merge data from another source's record for the same physical place.
    /// Never clears anything; user flags (isHidden) are preserved.
    mutating func merge(with incoming: Restaurant) {
        lists.formUnion(incoming.lists)
        if let award = incoming.michelinAward { michelinAward = award }
        if let years = incoming.michelinYears { michelinYears = years }
        if let former = incoming.michelinFormer { michelinFormer = former }
        if let names = incoming.localizedNames {
            localizedNames = (localizedNames ?? [:]).merging(names) { _, new in new }
        }
        if let band = incoming.priceBand { priceBand = band }
        if cuisine == nil { cuisine = incoming.cuisine }
        if summary == nil { summary = incoming.summary }
        if imageURL == nil { imageURL = incoming.imageURL }
        if uberEatsURL == nil { uberEatsURL = incoming.uberEatsURL }
        if uberEatsNotFoundAt == nil { uberEatsNotFoundAt = incoming.uberEatsNotFoundAt }
        if mapsNoMatchAt == nil {
            mapsNoMatchAt = incoming.mapsNoMatchAt
            mapsNoMatchName = incoming.mapsNoMatchName
        }
        if coordinate == nil, incoming.coordinate != nil {
            latitude = incoming.latitude
            longitude = incoming.longitude
        }
        if address == nil { address = incoming.address }
        if googleMapsURL == nil { googleMapsURL = incoming.googleMapsURL }
        if michelinURL == nil { michelinURL = incoming.michelinURL }
        addedManually = addedManually || incoming.addedManually
        for (source, date) in incoming.lastSeenInSourceAt {
            lastSeenInSourceAt[source] = max(date, lastSeenInSourceAt[source] ?? .distantPast)
        }
    }
}
