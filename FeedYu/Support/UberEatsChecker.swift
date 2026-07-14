import Foundation
import CoreLocation

/// Best-effort "is this restaurant on Uber Eats?" check.
///
/// Transport: a hidden WKWebView (WebPageFetcher) — ubereats.com serves a
/// JS bot-defense shell to bare URLSession requests (verified via device
/// logs), so the page must actually render in WebKit.
///
/// Matching: the search page's feed JSON carries each store's
/// "storeUuid" + "title" (+ often latitude/longitude). A candidate verifies
/// when it sits within 100 m of our saved coordinates AND its name
/// fuzzy-matches; candidates without coordinates in the feed get their
/// store page fetched and its JSON-LD GeoCoordinates checked instead.
/// Verified matches produce the canonical
/// /store-browse-uuid/<uuid>?diningMode=DELIVERY deep link.
///
/// Outcomes:
/// - available(storeURL): verified to exist AND affirmed open (allow-list;
///   see `orderableStates`) — the order button deep-links to the store.
/// - notFound: real results, nothing verified → engine rolls another.
/// - unknown: cannot affirm (bot wall, transport failure, nothing rendered)
///   → SKIPPED, never persisted (product call 2026-07-14: only stores known
///   to be ready get a card; a bot-wall session shows fewer cards instead
///   of unorderable ones).
@MainActor
final class UberEatsChecker: ObservableObject {
    static let shared = UberEatsChecker()

    enum Availability: Equatable {
        case available(URL?)
        /// Verified to exist, but not accepting orders right now (Uber
        /// would show "closed, accepts orders during open hours").
        /// `reopens` = Uber's nextOpenTime, used to expire the cache.
        case closedNow(URL?, reopens: Date?)
        case notFound
        case unknown
    }

    /// Verified matches must be this close to our saved coordinates.
    static let matchRadiusMeters: CLLocationDistance = 100
    /// Store pages fetched per check, at most (WebView loads are slow).
    static let maxStorePageFetches = 2
    /// A verified notFound persists in the store and is not re-checked for
    /// this long — restaurants do join Uber Eats, so it's a cooldown, not
    /// a verdict. `unknown` (bot wall) is never persisted.
    static let notFoundCooldownSeconds: TimeInterval = 7 * 24 * 3600

    /// True while a persisted verified notFound is still fresh — skip the
    /// slow WebView check entirely.
    nonisolated static func isInNotFoundCooldown(_ restaurant: Restaurant, now: Date = Date()) -> Bool {
        guard restaurant.uberEatsURL == nil,
              let checkedAt = restaurant.uberEatsNotFoundAt else { return false }
        return now.timeIntervalSince(checkedAt) < notFoundCooldownSeconds
    }

    /// True while a persisted verified "closed until Uber's reopen time"
    /// is still in the future — skip the WebView check AND the suggestion
    /// for free (an afternoon of closed restaurants used to cost one live
    /// check each, on every launch). The stamp only ever SUPPRESSES: once
    /// it passes, the live open check decides again, so it can never put
    /// a closed store on the card.
    nonisolated static func isClosedSuppressed(_ restaurant: Restaurant, now: Date = Date()) -> Bool {
        restaurant.uberEatsClosedUntil.map { now < $0 } ?? false
    }

    /// Session cache keyed by restaurant id — NOT by name: two same-named
    /// branches of a chain would share a verdict, and the first branch's
    /// verified store URL would get persisted onto the other (the engine's
    /// availabilityCheck writes `.available` URLs to the store). notFound
    /// lasts the session (existence rarely changes); `.available`
    /// (search-pipeline verdicts, URL-less flow only) and `unknown` expire
    /// after `openStateTTL` — unknown now HIDES a store, so a transient bot
    /// wall at launch must not suppress it all session; `.closedNow`
    /// self-expires at Uber's own reopen time. Known stores are
    /// deliberately NOT served a cached "open" — see
    /// `availability(for:near:)`.
    private var cache: [UUID: (result: Availability, at: Date)] = [:]
    nonisolated static let openStateTTL: TimeInterval = 10 * 60

    /// Pure freshness rule (testable): is a cached verdict still valid?
    nonisolated static func isFresh(_ result: Availability, checkedAt: Date, now: Date = Date()) -> Bool {
        switch result {
        case .available, .unknown: return now.timeIntervalSince(checkedAt) < openStateTTL
        case .closedNow(_, let reopens):
            // No reopen moment = a merchant pause (not a schedule closure):
            // recheck after openStateTTL, matching the persisted 10-minute
            // fallback — distantFuture would pin it closed all session.
            guard let reopens else { return now.timeIntervalSince(checkedAt) < openStateTTL }
            return now < reopens
        case .notFound: return true
        }
    }

    func availability(for restaurant: Restaurant, near origin: CLLocation?) async -> Availability {
        let key = restaurant.id
        if let url = restaurant.uberEatsURL {
            // Known store: existence is settled, so only the open-now
            // question remains — and it is answered LIVE on every
            // suggestion, DELIBERATELY uncached (product decision, don't
            // "optimize"): the card is the moment before the user taps
            // "order", and a cached "open" from even 10 minutes ago can be
            // a closed store by now. One getStoreV1 JSON call per shown
            // suggestion is the price of the button always landing on an
            // orderable page. Only a still-fresh closedNow short-circuits
            // — it self-expires at Uber's own reopen time, so it can't go
            // stale in the wrong direction.
            // Persisted suppression first (survives relaunches; the
            // in-memory closedNow below is its session-local twin).
            if Self.isClosedSuppressed(restaurant) {
                return .closedNow(url, reopens: restaurant.uberEatsClosedUntil)
            }
            if let cached = cache[key], case .closedNow = cached.result {
                if Self.isFresh(cached.result, checkedAt: cached.at) { return cached.result }
                cache[key] = nil
            }
            let region = (Locale.current.region?.identifier ?? "US").lowercased()
            guard let uuid = Self.storeUUID(fromStoreURL: url) else {
                // Only store-browse-uuid links are ever persisted, so this
                // is theoretical — but an unparseable URL means no open
                // check can run, and unverifiable stores don't get cards.
                Self.debugLog("un-parseable store URL for '\(restaurant.name)' — skipping (cannot affirm ready)")
                return .unknown
            }
            guard let info = await Self.fetchClosedInfo(storeUuid: uuid, region: region, origin: origin) else {
                // Cannot affirm ready (bot wall / transport, already
                // retried once) → SKIP, deliberately uncached and never
                // persisted: the failure says nothing about the
                // restaurant, and the very next roll may reach a warm
                // WebView. Product call 2026-07-14 — this used to fail
                // OPEN, and a store Uber couldn't vouch for got a card.
                Self.debugLog("open-check unavailable for known store '\(restaurant.name)' — skipping (cannot affirm ready)")
                return .unknown
            }
            if info.closed {
                let result = Availability.closedNow(url, reopens: info.reopens)
                cache[key] = (result, Date())
                return result
            }
            return .available(url)
        }
        if let cached = cache[key] {
            if Self.isFresh(cached.result, checkedAt: cached.at) { return cached.result }
            cache[key] = nil // stale open-state — recheck below
        }
        if Self.isInNotFoundCooldown(restaurant) { return .notFound }
        let result = await Self.fetchAvailability(name: restaurant.name,
                                                  coordinate: restaurant.coordinate,
                                                  origin: origin)
        cache[key] = (result, Date())
        return result
    }

    /// The raw uuid tail of a /store-browse-uuid/<uuid> deep link (the only
    /// form this app persists).
    nonisolated static func storeUUID(fromStoreURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "store-browse-uuid"),
              index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }

    /// Universal link fallback: opens the Uber Eats app's search when
    /// installed (iOS hands it to the app locally — the bot wall never runs),
    /// else the website in Safari.
    nonisolated static func searchURL(for name: String) -> URL {
        var components = URLComponents(string: "https://www.ubereats.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        return components.url!
    }

    // MARK: - Fetch pipeline (same-origin API calls from a bot-cleared page)

    static func fetchAvailability(name: String,
                                  coordinate: CLLocationCoordinate2D?,
                                  origin: CLLocation?) async -> Availability {
        // The HTML frontend gates /search behind a location-confirmation
        // redirect (verified via device logs). Instead: same-origin fetch()
        // against Uber's own search API from a bot-cleared page — the
        // location cookie set via document.cookie is honored there.
        let script = """
        try {
            if (locJSON.length > 0) {
                document.cookie = "uev2.loc=" + encodeURIComponent(locJSON) + "; path=/";
            }
            const res = await fetch("/api/getSearchSuggestionsV1?localeCode=" + region, {
                method: "POST",
                headers: {"content-type": "application/json", "x-csrf-token": "x"},
                body: JSON.stringify({userQuery: q, date: "", startTime: 0, endTime: 0, vertical: "ALL"})
            });
            const text = await res.text();
            return res.status + "|" + text;
        } catch (e) {
            return "0|" + String(e);
        }
        """
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        let arguments: [String: Any] = [
            "q": name,
            "locJSON": locationJSON(for: origin),
            "region": region,
        ]
        let host = URL(string: "https://www.ubereats.com/")!
        var response = await Self.runJS(script, arguments, host)
        if response == nil || response!.hasPrefix("0|") {
            // First call after a cold page load occasionally throws — retry once.
            try? await Task.sleep(nanoseconds: openCheckRetryDelayNanoseconds)
            response = await Self.runJS(script, arguments, host)
        }
        guard let response else {
            debugLog("search '\(name)': API call failed")
            return .unknown
        }
        let status = Int(response.prefix(while: { $0 != "|" })) ?? -1
        let body = String(response.drop(while: { $0 != "|" }).dropFirst())
        guard status == 200 else {
            debugLog("search '\(name)': API HTTP \(status), body head: \(String(body.prefix(200)))")
            return .unknown
        }
        let candidates = parseStoreCandidates(fromHTML: body)
        debugLog("search '\(name)': \(candidates.count) candidates from API, \(body.count) chars")
        guard !candidates.isEmpty else {
            if body.contains("\"data\"") {
                debugLog("'\(name)': API returned no stores")
                return .notFound
            }
            dumpDebugHTML(body, name: "debug-uber-api.txt")
            return .unknown
        }

        let target = Restaurant.normalize(name)
        let ranked = candidates
            .map { (candidate: $0, score: similarity(target, Restaurant.normalize($0.slug))) }
            .filter { $0.score >= 0.3 }
            .sorted { $0.score > $1.score }
        guard !ranked.isEmpty else { return .notFound }

        // Pass 1: candidates that carry coordinates in the feed JSON.
        var unlocated: [(score: Double, candidate: StoreCandidate)] = []
        for entry in ranked {
            if let storeLocation = entry.candidate.location, let coordinate {
                let distance = storeLocation.distance(from: CLLocation(latitude: coordinate.latitude,
                                                                       longitude: coordinate.longitude))
                debugLog("candidate '\(entry.candidate.slug)': \(Int(distance)) m away (feed geo), score \(String(format: "%.2f", entry.score))")
                if distance <= matchRadiusMeters, entry.score >= 0.5 {
                    debugLog("verified '\(name)' → \(entry.candidate.url.path)")
                    guard let uuid = entry.candidate.uuid,
                          let info = await fetchClosedInfo(storeUuid: uuid, region: region, origin: origin) else {
                        // Verified to exist, but the open check couldn't
                        // run — existence alone no longer earns a card
                        // (only-known-ready, 2026-07-14). Never persisted,
                        // 10-min session cache, so it retries soon.
                        debugLog("'\(name)' verified but open state unaffirmed — skipping")
                        return .unknown
                    }
                    if info.closed {
                        debugLog("'\(name)' is closed (reopens: \(info.reopens.map(String.init(describing:)) ?? "unknown"))")
                        return .closedNow(entry.candidate.url, reopens: info.reopens)
                    }
                    return .available(entry.candidate.url)
                }
            } else {
                unlocated.append((entry.score, entry.candidate))
            }
        }

        // Pass 2: geo via the getStoreV1 API (fast JSON, no page render).
        var verifiedAny = false
        for entry in unlocated.prefix(maxStorePageFetches) {
            guard let uuid = entry.candidate.uuid,
                  let storeBody = await fetchStoreBody(storeUuid: uuid, region: region, origin: origin) else {
                debugLog("store lookup failed for '\(entry.candidate.slug)'")
                continue
            }
            verifiedAny = true
            let store = parseStorePage(fromHTML: storeBody)
            let score = max(entry.score,
                            store.name.map { similarity(target, Restaurant.normalize($0)) } ?? 0)
            if let storeLocation = store.location, let coordinate {
                let distance = storeLocation.distance(from: CLLocation(latitude: coordinate.latitude,
                                                                       longitude: coordinate.longitude))
                debugLog("store '\(entry.candidate.slug)': \(Int(distance)) m away (getStoreV1), score \(String(format: "%.2f", score))")
                if distance <= matchRadiusMeters, score >= 0.5 {
                    debugLog("verified '\(name)' → \(entry.candidate.url.path)")
                    let info = parseClosedInfo(fromStoreJSON: storeBody)
                    if info.closed {
                        debugLog("'\(name)' is closed (reopens: \(info.reopens.map(String.init(describing:)) ?? "unknown"))")
                        return .closedNow(entry.candidate.url, reopens: info.reopens)
                    }
                    return .available(entry.candidate.url)
                }
            } else if score >= 0.85 {
                // No geo anywhere → only a near-certain name match passes.
                let info = parseClosedInfo(fromStoreJSON: storeBody)
                if info.closed {
                    return .closedNow(entry.candidate.url, reopens: info.reopens)
                }
                return .available(entry.candidate.url)
            }
        }
        if unlocated.isEmpty || verifiedAny {
            debugLog("'\(name)': not found")
            return .notFound
        }
        debugLog("'\(name)': unverifiable (store lookups failed)")
        return .unknown
    }

    /// Transport for the same-origin JS calls — injectable for tests: the
    /// WebView needs a real app and ubereats.com bot-walls anything that
    /// isn't one, so unit tests stub this and feed fixture JSON through
    /// the REAL retry/verdict logic (the same seam as the engine's
    /// etaProvider). Production runs the shared bot-cleared WKWebView.
    static var runJS: (_ script: String, _ arguments: [String: Any], _ hostPage: URL) async -> String? = { script, arguments, hostPage in
        await WebPageFetcher.shared.callJS(script, arguments: arguments, onHost: hostPage)
    }

    /// Cold-start retry pause; tests set 0 so retries don't slow the suite.
    static var openCheckRetryDelayNanoseconds: UInt64 = 1_000_000_000

    /// getStoreV1 JSON via a same-origin fetch (same transport as search).
    /// The uev2.loc cookie is load-bearing here too, verified live
    /// 2026-07-14: WITHOUT a location, getStoreV1 masks schedule closure
    /// behind TOO_FAR_TO_DELIVER and nulls nextOpenTime — BOTH closed
    /// signals vanish and a closed store reads as orderable. The cookie is
    /// session-scoped, so before this line every cold launch's known-store
    /// checks ran location-blind until a search-pipeline call happened to
    /// set it (a 22:00-opening steakhouse reached the lunch card this way).
    static func fetchStoreBody(storeUuid: String, region: String, origin: CLLocation?) async -> String? {
        let script = """
        try {
            if (locJSON.length > 0) {
                document.cookie = "uev2.loc=" + encodeURIComponent(locJSON) + "; path=/";
            }
            const res = await fetch("/api/getStoreV1?localeCode=" + region, {
                method: "POST",
                headers: {"content-type": "application/json", "x-csrf-token": "x"},
                body: JSON.stringify({storeUuid: uuid})
            });
            const text = await res.text();
            return res.status + "|" + text;
        } catch (e) {
            return "0|" + String(e);
        }
        """
        let host = URL(string: "https://www.ubereats.com/")!
        let arguments: [String: Any] = [
            "uuid": storeUuid,
            "region": region,
            "locJSON": locationJSON(for: origin),
        ]
        guard let response = await Self.runJS(script, arguments, host),
              response.hasPrefix("200|") else { return nil }
        return String(response.dropFirst(4))
    }

    /// getStoreV1 state vocabulary, verified against REAL captures
    /// (2026-07-11 and 2026-07-14; synthetic mirrors in tests).
    ///
    /// ALLOW-list (product call 2026-07-14: only stores KNOWN to be ready
    /// get a card): `AVAILABLE` is the one affirmed open state — captured
    /// live from an orderable store once curl probing became possible.
    /// Everything else is "not ready": NOT_ACCEPTING_ORDERS = merchant
    /// paused mid-shift (nextOpenTime null); STORE_CLOSED = outside
    /// scheduled hours (nextOpenTime set); TOO_FAR_TO_DELIVER /
    /// NO_COURIERS_NEARBY = Uber won't take the order from here right now;
    /// UNKNOWN = observed on a store INSIDE its open window that wasn't
    /// accepting (the exact card the old deny-list shipped). States in
    /// neither set are debug-logged so device consoles collect vocabulary
    /// drift — if Uber ever renames AVAILABLE, the tab goes visibly quiet
    /// until the allow-list is re-captured (see docs/MAINTENANCE.md).
    nonisolated static let orderableStates: Set<String> = ["AVAILABLE"]
    /// Known not-ready states, kept ONLY to separate "recognized closed"
    /// from "new vocabulary" in the debug log — both are skipped.
    nonisolated static let notOrderableStates: Set<String> =
        ["NOT_ACCEPTING_ORDERS", "STORE_CLOSED", "TOO_FAR_TO_DELIVER", "NO_COURIERS_NEARBY", "UNKNOWN"]

    /// `storeAvailablityStatus.state` — Uber's own "Availablity" typo is
    /// load-bearing; the pattern tolerates both spellings in case they
    /// ever fix it.
    nonisolated static func parseAvailabilityState(fromStoreJSON json: String) -> String? {
        guard let match = json.firstMatch(of: #/"storeAvailab(?:li|ili)tyStatus"\s*:\s*\{[^}]*?"state"\s*:\s*"([^"]+)"/#) else { return nil }
        return String(match.1)
    }

    /// The store-level "can you order right now" verdict from getStoreV1.
    /// nil = transport failure (callers SKIP — cannot affirm ready — and
    /// persist nothing). `(true, reopens)` = not orderable; reopens is
    /// Uber's schedule moment when there is one — merchant pauses have
    /// none, and callers apply the 10-minute recheck fallback.
    static func fetchClosedInfo(storeUuid: String, region: String, origin: CLLocation?) async -> (closed: Bool, reopens: Date?)? {
        var body = await fetchStoreBody(storeUuid: storeUuid, region: region, origin: origin)
        if body == nil {
            // Cold-start etiquette copied from fetchAvailability: the first
            // WebView call after a page load occasionally throws — and at
            // app launch the Uber tab's auto-roll makes THIS the app's
            // very first call whenever the top candidate is a known store.
            // Single-shot, the open check failed open and the initial card
            // could be a store that is closed right now (shipped once).
            try? await Task.sleep(nanoseconds: openCheckRetryDelayNanoseconds)
            body = await fetchStoreBody(storeUuid: storeUuid, region: region, origin: origin)
        }
        guard let body else { return nil }
        return parseClosedInfo(fromStoreJSON: body)
    }

    /// ALLOW-list verdict: `closed == false` only when the state is an
    /// affirmed orderable one (`orderableStates`) AND the schedule doesn't
    /// contradict it (a FUTURE nextOpenTime means "closed right now,
    /// accepts scheduled orders" — semantics verified live 2026-07-10).
    /// A missing state field (format drift), an unrecognized state, or a
    /// recognized not-ready state all mean "cannot affirm ready" → closed.
    /// nextOpenTime is kept only for the reopen stamp: an open store may
    /// report null OR a past value (both observed live), so it can never
    /// serve as an open signal on its own.
    /// `isOpen`/`isOrderable`/`isAvailable` are NOT open-now flags — all
    /// three were true for verifiably closed AND merchant-paused stores.
    nonisolated static func parseClosedInfo(fromStoreJSON json: String, now: Date = Date()) -> (closed: Bool, reopens: Date?) {
        let reopens = parseNextOpenTime(fromStoreJSON: json)
        guard let state = parseAvailabilityState(fromStoreJSON: json) else {
            debugLog("storeAvailablityStatus missing — cannot affirm ready")
            return (true, reopens)
        }
        if orderableStates.contains(state) {
            if let reopens, reopens > now { return (true, reopens) }
            return (false, reopens)
        }
        if !notOrderableStates.contains(state) {
            debugLog("storeAvailablityStatus '\(state)' in neither vocabulary set — treating as not ready")
        }
        return (true, reopens)
    }

    nonisolated static func parseNextOpenTime(fromStoreJSON json: String) -> Date? {
        guard let range = json.range(of: #""nextOpenTime"\s*:\s*"([^"]+)""#,
                                     options: .regularExpression) else { return nil }
        let match = String(json[range])
        guard let valueStart = match.range(of: #":"#)?.upperBound else { return nil }
        let value = match[valueStart...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// uev2.loc payload scoping ubereats.com to the user's position
    /// (uberLatLng = raw-coordinate reference type).
    nonisolated static func locationJSON(for origin: CLLocation?) -> String {
        guard let origin else { return "" }
        return """
        {"address":{"address1":"FeedYu"},"latitude":\(origin.coordinate.latitude),"longitude":\(origin.coordinate.longitude),"reference":"","referenceType":"uberLatLng","type":"uberLatLng"}
        """
    }

    // MARK: - Parsing (fixture-testable)

    struct StoreCandidate: Equatable {
        var slug: String
        var url: URL
        var location: CLLocation?
        var uuid: String?

        static func == (lhs: StoreCandidate, rhs: StoreCandidate) -> Bool {
            lhs.slug == rhs.slug && lhs.url == rhs.url
        }
    }

    /// Store references on a results page, deduped, order kept. Two shapes:
    ///
    /// 1. Embedded feed JSON: `"storeUuid":"<dashed-uuid>"` with a nearby
    ///    `"title"` (and often latitude/longitude) — these become canonical
    ///    /store-browse-uuid/<uuid>?diningMode=DELIVERY links.
    /// 2. Anchor hrefs: [/region]/store/<slug>/<id>. The region prefix is
    ///    kept (Taiwan links are /tw/store/…) and the path stays
    ///    percent-encoded — a decoded CJK path can't build a URL.
    nonisolated static func parseStoreCandidates(fromHTML html: String) -> [StoreCandidate] {
        let fullRange = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var result: [StoreCandidate] = []

        // "storeUuid" is the feed key; bare "uuid" appears in API suggestion
        // payloads — the latter only counts when its object carries a title
        // (plenty of non-store uuids float around otherwise).
        if let uuidRegex = try? NSRegularExpression(pattern: #""(storeUuid|uuid)"\s*:\s*"([0-9a-fA-F-]{36})""#) {
            for match in uuidRegex.matches(in: html, range: fullRange) {
                guard let keyRange = Range(match.range(at: 1), in: html),
                      let uuidRange = Range(match.range(at: 2), in: html) else { continue }
                let uuid = String(html[uuidRange]).lowercased()
                guard !seen.contains(uuid),
                      let url = URL(string: "https://www.ubereats.com/store-browse-uuid/\(uuid)?diningMode=DELIVERY") else { continue }
                // Title/geo come from THIS store's JSON object only — JSON
                // field order isn't guaranteed, and a char-distance guess
                // let stores inherit a neighbor's coordinates.
                let object = enclosingObject(in: html, around: uuidRange) ?? window(in: html, around: uuidRange)
                var title: String?
                if let titleMatch = object.firstMatch(of: #/"title"\s*:\s*"((?:[^"\\]|\\.)+)"/#) {
                    title = decodeJSONString(String(titleMatch.1))
                }
                if html[keyRange] == "uuid", title == nil { continue }
                seen.insert(uuid)
                var location: CLLocation?
                if let coordMatch = object.firstMatch(of: #/"latitude"\s*:\s*(-?\d{1,3}\.?\d*)\s*,\s*"longitude"\s*:\s*(-?\d{1,3}\.?\d*)/#),
                   let latitude = Double(coordMatch.1), let longitude = Double(coordMatch.2),
                   abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 {
                    location = CLLocation(latitude: latitude, longitude: longitude)
                }
                result.append(StoreCandidate(slug: title ?? "", url: url, location: location, uuid: uuid))
            }
        }

        if let hrefRegex = try? NSRegularExpression(pattern: #"(?:/[a-z]{2}(?:-[a-z]+)?)?/store/([^/"?\\]+)/([A-Za-z0-9_-]{20,})"#) {
            for match in hrefRegex.matches(in: html, range: fullRange) {
                guard let slugRange = Range(match.range(at: 1), in: html),
                      let fullRange = Range(match.range(at: 0), in: html) else { continue }
                let path = String(html[fullRange])
                guard !seen.contains(path),
                      let url = URL(string: "https://www.ubereats.com" + path + "?diningMode=DELIVERY") else { continue }
                seen.insert(path)
                let slug = String(html[slugRange]).removingPercentEncoding ?? String(html[slugRange])
                result.append(StoreCandidate(slug: slug, url: url, location: nil, uuid: nil))
            }
        }
        return result
    }

    /// The JSON object containing `anchor`, found by a balanced-brace scan
    /// (backward to the enclosing `{`, forward to its match). When the
    /// immediate object has no "title" (storeUuid sometimes sits in a tiny
    /// sub-object), expands outward up to 3 levels. Tolerant of malformed
    /// input: bails at scan caps and the caller falls back to a fixed window.
    nonisolated static func enclosingObject(in html: String, around anchor: Range<String.Index>) -> Substring? {
        var position = anchor.lowerBound
        var lastObject: Substring?
        for _ in 0..<3 {
            guard let open = openingBrace(in: html, before: position),
                  let end = closingBrace(in: html, from: open) else { break }
            let object = html[open..<end]
            lastObject = object
            if object.contains("\"title\"") { return object }
            guard open > html.startIndex else { break }
            position = open
        }
        return lastObject
    }

    nonisolated private static func openingBrace(in html: String, before position: String.Index) -> String.Index? {
        var depth = 0
        var index = position
        var steps = 0
        while index > html.startIndex, steps < 6000 {
            index = html.index(before: index)
            steps += 1
            let char = html[index]
            if char == "}" { depth += 1 }
            else if char == "{" {
                if depth == 0 { return index }
                depth -= 1
            }
        }
        return nil
    }

    nonisolated private static func closingBrace(in html: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        var steps = 0
        while index < html.endIndex, steps < 40_000 {
            let char = html[index]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return html.index(after: index) }
            }
            index = html.index(after: index)
            steps += 1
        }
        return nil
    }

    nonisolated private static func window(in html: String, around anchor: Range<String.Index>) -> Substring {
        let start = html.index(anchor.lowerBound, offsetBy: -800, limitedBy: html.startIndex) ?? html.startIndex
        let end = html.index(anchor.upperBound, offsetBy: 800, limitedBy: html.endIndex) ?? html.endIndex
        return html[start..<end]
    }

    struct StoreInfo: Equatable {
        var name: String?
        var location: CLLocation?

        static func == (lhs: StoreInfo, rhs: StoreInfo) -> Bool {
            lhs.name == rhs.name
                && lhs.location?.coordinate.latitude == rhs.location?.coordinate.latitude
                && lhs.location?.coordinate.longitude == rhs.location?.coordinate.longitude
        }
    }

    /// Single-store payloads: a store page's schema.org JSON-LD ("geo"
    /// block, Restaurant name) or a getStoreV1 API response (bare
    /// latitude/longitude in "location", "title"). Tolerant regex scan.
    nonisolated static func parseStorePage(fromHTML html: String) -> StoreInfo {
        var info = StoreInfo()
        if let match = html.firstMatch(of: #/"geo"\s*:\s*\{[^}]*?"latitude"\s*:\s*(-?\d{1,3}\.?\d*)\s*,\s*"longitude"\s*:\s*(-?\d{1,3}\.?\d*)/#),
           let latitude = Double(match.1), let longitude = Double(match.2),
           abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 {
            info.location = CLLocation(latitude: latitude, longitude: longitude)
        } else if let match = html.firstMatch(of: #/"latitude"\s*:\s*(-?\d{1,3}\.?\d*)\s*,\s*"longitude"\s*:\s*(-?\d{1,3}\.?\d*)/#),
                  let latitude = Double(match.1), let longitude = Double(match.2),
                  abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 {
            info.location = CLLocation(latitude: latitude, longitude: longitude)
        }
        if let match = html.firstMatch(of: #/"@type"\s*:\s*"Restaurant"[^}]*?"name"\s*:\s*"((?:[^"\\]|\\.)+)"/#) {
            info.name = decodeJSONString(String(match.1))
        } else if let match = html.firstMatch(of: #/"title"\s*:\s*"((?:[^"\\]|\\.)+)"/#) {
            info.name = decodeJSONString(String(match.1))
        } else if let match = html.firstMatch(of: #/"name"\s*:\s*"((?:[^"\\]|\\.)+)"/#) {
            info.name = decodeJSONString(String(match.1))
        }
        return info
    }

    nonisolated private static func decodeJSONString(_ raw: String) -> String {
        (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? raw
    }

    // MARK: - Fuzzy matching

    /// 0…1 similarity of two normalized names: containment (slugs append
    /// city/branch qualifiers) scores by length ratio with a floor, else
    /// normalized Levenshtein.
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            return max(0.7, ratio)
        }
        let distance = levenshtein(Array(a.prefix(48)), Array(b.prefix(48)))
        return 1 - Double(distance) / Double(max(min(a.count, 48), min(b.count, 48)))
    }

    nonisolated private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Visible via `devicectl device process launch --console` — the WebView
    /// flow only runs in a real app, so the device build has to tell us what
    /// actually happened. (The JSON APIs themselves answered plain curl with
    /// a mobile Safari UA as of 2026-07-14 — see docs/MAINTENANCE.md for the
    /// payload-probe recipe — but the bot wall's behavior drifts; the console
    /// is ground truth for what the app saw.)
    nonisolated static func debugLog(_ message: String) {
        #if DEBUG
        print("[UberEats] \(message)")
        #endif
    }

    nonisolated private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// DEBUG builds drop the last unparseable page next to store.json so it
    /// can be pulled via devicectl app-container copy and inspected — the
    /// only way to see what Uber actually renders on-device.
    nonisolated private static func dumpDebugHTML(_ html: String, name: String) {
        #if DEBUG
        let url = RestaurantStore.storeFileURL.deletingLastPathComponent().appendingPathComponent(name)
        try? Data(html.utf8).write(to: url)
        debugLog("dumped \(html.count) chars to \(name)")
        #endif
    }
}
