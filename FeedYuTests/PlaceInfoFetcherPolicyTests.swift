import XCTest
import CoreLocation
@testable import FeedYu

/// The cid-resolution caching policy through the REAL `resolvedMapsURL`
/// logic, with the search transport stubbed (`PlaceInfoFetcher.resolveCid`
/// — the etaProvider/runJS seam): what gets cached, what persists, and
/// what earns a retry each shipped from a debugging session, so they are
/// contracts, not incidents. See docs/REQUIREMENTS.md "Sync & network
/// etiquette".
@MainActor
final class PlaceInfoFetcherPolicyTests: XCTestCase {
    private var store: RestaurantStore!
    private var seeded: Restaurant!

    override func setUp() async throws {
        store = RestaurantStore()
        var r = Restaurant(name: "Uosho")
        r.latitude = 35.6586
        r.longitude = 139.7454
        r.address = "Tokyo, JPN"
        store.apply([r], sourceID: "takeout-starred")
        seeded = store.restaurants[0]
    }

    override func tearDown() async throws {
        PlaceInfoFetcher.resolveCid = {
            await GooglePlaceResolver.resolveCid(name: $0, coordinate: $1, allowsExpensiveNetwork: $2)
        }
    }

    func testDefinitiveNoMatchPersistsACooldownHonoredAcrossSessions() async {
        var calls = 0
        PlaceInfoFetcher.resolveCid = { _, _, _ in calls += 1; return .noMatch }
        let url = await PlaceInfoFetcher().resolvedMapsURL(for: seeded, store: store)
        XCTAssertNil(url)
        XCTAssertEqual(calls, 1)
        let row = store.restaurant(withID: seeded.id)!
        XCTAssertNotNil(row.mapsNoMatchAt, "a data-bearing no-match is worth persisting")
        XCTAssertEqual(row.mapsNoMatchName, "Uosho")
        // A NEW session (fresh fetcher = relaunch) honors the cooldown:
        // each retry is a 1–2 MB search page, not re-spent for 30 days.
        _ = await PlaceInfoFetcher().resolvedMapsURL(for: row, store: store)
        XCTAssertEqual(calls, 1, "cooldown blocks the refetch")
    }

    func testTransientFailureNeverPersistsAndRetriesSameSession() async {
        let fetcher = PlaceInfoFetcher()
        PlaceInfoFetcher.resolveCid = { _, _, _ in .unavailable }
        let first = await fetcher.resolvedMapsURL(for: seeded, store: store)
        XCTAssertNil(first)
        XCTAssertNil(store.restaurant(withID: seeded.id)?.mapsNoMatchAt,
                     "shell pages / network errors say nothing about the place")
        // The tap that follows a failed warm-up deserves a real retry —
        // same fetcher, same session.
        PlaceInfoFetcher.resolveCid = { _, _, _ in .resolved("1234567890") }
        let url = await fetcher.resolvedMapsURL(for: seeded, store: store)
        XCTAssertEqual(url?.absoluteString, "https://maps.google.com/?cid=1234567890")
        XCTAssertEqual(store.restaurant(withID: seeded.id)?.googleMapsURL, url,
                       "a resolved cid persists so every later tap is exact")
    }

    func testNewlyLocalizedNameGrantsAFreshAttempt() async {
        let fetcher = PlaceInfoFetcher()
        var searched: [String] = []
        PlaceInfoFetcher.resolveCid = { name, _, _ in searched.append(name); return .noMatch }
        _ = await fetcher.resolvedMapsURL(for: seeded, store: store)
        _ = await fetcher.resolvedMapsURL(for: seeded, store: store)
        XCTAssertEqual(searched, ["Uosho"], "second call is session-gated")
        // The localizer lands the local-market name Google can actually
        // match — that name earns one fresh attempt despite the session
        // gate AND the persisted cooldown (both are keyed to the name).
        store.setLocalizedName(id: seeded.id, editionKey: "ja", name: "魚庄")
        let live = store.restaurant(withID: seeded.id)!
        _ = await fetcher.resolvedMapsURL(for: live, store: store)
        XCTAssertEqual(searched, ["Uosho", "魚庄", "Uosho"],
                       "new search name first, dataset romanization second")
    }

    func testCancelledWarmUpDoesNotBurnTheTapsRetry() async {
        // Card warm-up cancelled mid-fetch (view disappeared): the attempt
        // must not be recorded — the user's tap right after deserves a
        // real resolution, not the search fallback for the session.
        let fetcher = PlaceInfoFetcher()
        PlaceInfoFetcher.resolveCid = { _, _, _ in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return .noMatch
        }
        let warmUp = Task { await fetcher.resolvedMapsURL(for: seeded, store: store) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        warmUp.cancel()
        let url = await warmUp.value
        XCTAssertNil(url)
        XCTAssertNil(store.restaurant(withID: seeded.id)?.mapsNoMatchAt,
                     "a cancelled attempt is not a verdict")
        PlaceInfoFetcher.resolveCid = { _, _, _ in .resolved("42") }
        let resolved = await fetcher.resolvedMapsURL(for: seeded, store: store)
        XCTAssertEqual(resolved?.absoluteString, "https://maps.google.com/?cid=42")
    }
}
