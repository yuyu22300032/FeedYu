import Foundation

/// Lazily fetches local-language restaurant names from the Michelin Guide's
/// locale editions (the same slug serves every locale). Results are cached in
/// the store, so each name is fetched once, ever. Throttled and bounded —
/// names fill in progressively while browsing.
@MainActor
final class MichelinNameLocalizer: ObservableObject {
    /// Michelin's bot filter rejects desktop CLI agents but serves mobile
    /// Safari — which is what this app effectively is.
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static let editionPaths: [String: String] = [
        "zh_TW": "tw/zh_TW",
        "ja": "jp/ja",
        "zh_HK": "hk/zh_HK",
        "zh_CN": "cn/zh_CN",
    ]

    private var failedKeys: Set<String> = []
    private var isRunning = false
    private let maxFetchesPerRun = 40

    /// Fill missing localized names for the given (already prioritized)
    /// restaurants. Call freely; overlapping calls are ignored.
    func fill(restaurants: [Restaurant], nameLanguage: String, store: RestaurantStore) async {
        guard nameLanguage != "en", !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var fetched = 0
        for restaurant in restaurants {
            guard fetched < maxFetchesPerRun else { break }
            guard let editionKey = restaurant.editionKey(preference: nameLanguage),
                  restaurant.localizedNames?[editionKey] == nil,
                  let guideURL = restaurant.michelinURL,
                  let editionURL = Self.editionURL(for: guideURL, editionKey: editionKey) else { continue }
            let cacheKey = "\(restaurant.id.uuidString)|\(editionKey)"
            guard !failedKeys.contains(cacheKey) else { continue }

            fetched += 1
            if let name = await Self.fetchName(from: editionURL) {
                store.setLocalizedName(id: restaurant.id, editionKey: editionKey, name: name)
            } else {
                failedKeys.insert(cacheKey)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    static func editionURL(for url: URL, editionKey: String) -> URL? {
        guard let path = editionPaths[editionKey],
              url.host?.hasSuffix("guide.michelin.com") == true,
              url.absoluteString.contains("guide.michelin.com/en/") else { return nil }
        let rewritten = url.absoluteString.replacingOccurrences(
            of: "guide.michelin.com/en/", with: "guide.michelin.com/\(path)/")
        return URL(string: rewritten)
    }

    static func fetchName(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseTitleName(fromHTML: String(decoding: data.prefix(200_000), as: UTF8.self))
    }

    /// Page titles look like "頤宮 – Taipei - a MICHELIN Guide Restaurant" or
    /// "青空／Harutaka - 東京 - ミシュランガイドレストラン" — the name is the
    /// first segment.
    static func parseTitleName(fromHTML html: String) -> String? {
        guard let start = html.range(of: "<title>"),
              let end = html.range(of: "</title>", range: start.upperBound..<html.endIndex) else { return nil }
        let title = String(html[start.upperBound..<end.lowerBound])
        let name = title
            .components(separatedBy: " – ").first!
            .components(separatedBy: " - ").first!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.lowercased().contains("michelin"), !name.contains("ミシュラン") else { return nil }
        return name
    }
}
