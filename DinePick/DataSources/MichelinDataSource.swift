import Foundation
import CoreLocation

/// Michelin restaurants (1–3 stars + Bib Gourmand) from the open
/// michelin-my-maps dataset. A preprocessed snapshot is bundled with the app;
/// it auto-refreshes from GitHub when older than a week, falling back to the
/// last good local copy.
final class MichelinDataSource: RestaurantDataSource {
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/ngshiheng/michelin-my-maps/main/data/michelin_my_maps.csv")!
    static let bundledSnapshotDate = "2026-07-05"
    static let refreshInterval: TimeInterval = 7 * 24 * 3600
    private static let lastRefreshKey = "michelinLastRemoteRefresh"

    let id = "michelin"
    let displayName = "Michelin Guide"
    private let forceRemote: Bool

    init(forceRemote: Bool = false) {
        self.forceRemote = forceRemote
    }

    nonisolated static var cachedFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DinePick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("michelin-cache.csv")
    }

    static var lastRemoteRefresh: Date? {
        get { UserDefaults.standard.object(forKey: lastRefreshKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastRefreshKey) }
    }

    static var datasetDateDescription: String {
        if let refreshed = lastRemoteRefresh {
            return refreshed.formatted(date: .abbreviated, time: .omitted)
        }
        return String(localized: "bundled snapshot \(bundledSnapshotDate)")
    }

    func fetch() async throws -> [Restaurant] {
        let current: [Restaurant]
        if forceRemote {
            current = try await refreshFromRemote()
        } else {
            let isStale = (Self.lastRemoteRefresh.map { Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true
            if isStale, let fresh = try? await refreshFromRemote() {
                current = fresh
            } else {
                current = try loadLocal()
            }
        }
        return Self.applyHistoryOverlay(to: current, historyCSV: Self.bundledHistoryCSV())
    }

    static func bundledHistoryCSV() -> String? {
        guard let url = Bundle.main.url(forResource: "michelin_history", withExtension: "csv"),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Attaches "years on the list" to current places and appends former
    /// places (dropped from the current guide) marked michelinFormer.
    static func applyHistoryOverlay(to current: [Restaurant], historyCSV: String?) -> [Restaurant] {
        guard let historyCSV else { return current }
        var result = current
        var indexByName: [String: [Int]] = [:]
        for (index, r) in result.enumerated() {
            indexByName[r.normalizedName, default: []].append(index)
        }
        for record in CSVParser.parseRecords(historyCSV) {
            guard let name = record["Name"], !name.isEmpty,
                  let years = record["Years"], !years.isEmpty,
                  let latitude = record["Latitude"].flatMap(Double.init),
                  let longitude = record["Longitude"].flatMap(Double.init) else { continue }
            let location = CLLocation(latitude: latitude, longitude: longitude)
            let matched = indexByName[Restaurant.normalize(name)]?.first { index in
                guard let existing = result[index].location else { return false }
                return existing.distance(from: location) <= 500
            }
            if record["Current"] == "1" {
                if let matched { result[matched].michelinYears = years }
            } else if matched == nil,
                      let award = MichelinAward(datasetValue: record["Award"] ?? "") {
                var former = Restaurant(name: name)
                former.latitude = latitude
                former.longitude = longitude
                former.address = nonEmpty(record["Address"]) ?? nonEmpty(record["Location"])
                former.michelinURL = nonEmpty(record["Url"]).flatMap(URL.init(string:))
                former.michelinAward = award
                former.michelinYears = years
                former.michelinFormer = true
                former.priceBand = priceBand(from: record["Price"] ?? "")
                former.cuisine = nonEmpty(record["Cuisine"])
                former.summary = nonEmpty(record["Description"]).map { String($0.prefix(200)) }
                result.append(former)
            }
        }
        return result
    }

    func loadLocal() throws -> [Restaurant] {
        if let data = try? Data(contentsOf: Self.cachedFileURL), !data.isEmpty {
            let parsed = Self.parseCSV(String(decoding: data, as: UTF8.self))
            if !parsed.isEmpty { return parsed }
        }
        guard let bundled = Bundle.main.url(forResource: "michelin", withExtension: "csv"),
              let data = try? Data(contentsOf: bundled) else {
            throw SourceError.unreadableFile(String(localized: "Bundled michelin.csv is missing."))
        }
        let parsed = Self.parseCSV(String(decoding: data, as: UTF8.self))
        guard !parsed.isEmpty else {
            throw SourceError.parseFailed(String(localized: "Could not parse the bundled Michelin dataset."))
        }
        return parsed
    }

    private func refreshFromRemote() async throws -> [Restaurant] {
        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SourceError.httpStatus(http.statusCode)
        }
        let parsed = Self.parseCSV(String(decoding: data, as: UTF8.self))
        guard parsed.count > 100 else {
            throw SourceError.parseFailed(String(localized: "Remote Michelin CSV parsed to only \(parsed.count) rows — format may have changed."))
        }
        try? data.write(to: Self.cachedFileURL, options: .atomic)
        Self.lastRemoteRefresh = Date()
        return parsed
    }

    /// Works on both the full upstream CSV and the reduced bundled snapshot
    /// (columns are looked up by header name). Keeps only stars + Bib Gourmand.
    static func parseCSV(_ text: String) -> [Restaurant] {
        let records = CSVParser.parseRecords(text)
        var result: [Restaurant] = []
        result.reserveCapacity(8000)
        for record in records {
            guard let awardText = record["Award"],
                  let award = MichelinAward(datasetValue: awardText),
                  let name = record["Name"], !name.isEmpty else { continue }
            let latitude = record["Latitude"].flatMap(Double.init)
            let longitude = record["Longitude"].flatMap(Double.init)
            var restaurant = Restaurant(name: name)
            restaurant.latitude = latitude
            restaurant.longitude = longitude
            restaurant.address = nonEmpty(record["Address"]) ?? nonEmpty(record["Location"])
            restaurant.michelinURL = nonEmpty(record["Url"]).flatMap(URL.init(string:))
            restaurant.michelinAward = award
            restaurant.priceBand = priceBand(from: record["Price"] ?? "")
            restaurant.cuisine = nonEmpty(record["Cuisine"])
            restaurant.summary = nonEmpty(record["Description"]).map { String($0.prefix(200)) }
            result.append(restaurant)
        }
        return result
    }

    /// Rewrites a guide.michelin.com/en/… URL to the device-language edition
    /// (same slugs work across locales) so the guide page shows the local
    /// name and description.
    static func localizedGuideURL(_ url: URL) -> URL {
        guard url.host?.hasSuffix("guide.michelin.com") == true else { return url }
        let language = Locale.preferredLanguages.first ?? "en"
        let localePath: String
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") {
            localePath = "tw/zh_TW"
        } else if language.hasPrefix("ja") {
            localePath = "jp/ja"
        } else {
            return url
        }
        let rewritten = url.absoluteString.replacingOccurrences(
            of: "guide.michelin.com/en/", with: "guide.michelin.com/\(localePath)/")
        return URL(string: rewritten) ?? url
    }

    /// Price symbols vary by locale ($$$, €€€, ¥¥¥¥, ££…) — band = symbol
    /// count, clamped 1–4.
    static func priceBand(from price: String) -> Int? {
        let trimmed = price.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return min(4, max(1, trimmed.count))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
