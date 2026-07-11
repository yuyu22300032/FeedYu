import SwiftUI
import CoreLocation

/// Main screen: opens straight to one suggestion from the user's saved places,
/// reachable within the drive-time budget in current traffic.
struct TonightView: View {
    /// true = the Uber Eats tab: identical candidates and engine, plus a
    /// "can you actually order it?" filter and an order button on the card.
    var uberEatsMode = false

    @EnvironmentObject private var store: RestaurantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var locationProvider: LocationProvider
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = SuggestionEngine()
    /// After 1 s of searching, the loading card takes over even from a
    /// still-visible previous suggestion — a long exhaustive Uber check
    /// behind a stale card reads as a frozen app.
    @State private var searchIsSlow = false
    /// The button-started search, kept so leaving the tab can cancel it —
    /// an Uber scan otherwise keeps burning slow WebView checks for a card
    /// nobody is looking at. (The auto-suggest path is a .task, so its
    /// cancellation is already tied to the view's lifetime.)
    @State private var refreshTask: Task<Void, Never>?

    /// The user's own saved places (not the whole Michelin dataset), drawn
    /// only from lists enabled in Settings *for this tab* (Tonight and Uber
    /// Eats toggle independently). Membership is tracked by which sources
    /// have stamped the place (lastSeenInSourceAt).
    /// Memoized like MichelinView.michelinInRange: read several times per
    /// body evaluation, and each uncached compute scans the whole store.
    private final class CandidatesCache {
        var key: String?
        var value: [Restaurant] = []
    }
    @State private var candidatesCache = CandidatesCache()

    private var candidates: [Restaurant] {
        let enabledSourceIDs = settings.enabledListSourceIDs(forUberEats: uberEatsMode)
        let key = "\(store.version)|\(enabledSourceIDs.sorted().joined(separator: ","))"
        if candidatesCache.key == key { return candidatesCache.value }
        let result = store.restaurants.filter { restaurant in
            guard !restaurant.isHidden, restaurant.coordinate != nil else { return false }
            if restaurant.addedManually { return true }
            return restaurant.lastSeenInSourceAt.keys.contains { enabledSourceIDs.contains($0) }
        }
        candidatesCache.key = key
        candidatesCache.value = result
        return result
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Grouped-style colors app-wide: gray page, white boxes.
            .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var content: some View {
        if locationProvider.isDenied {
            ContentUnavailableView {
                Label("Location needed", systemImage: "location.slash")
            } description: {
                Text("FeedYu filters suggestions by drive time from where you are. Allow location access in the Settings app.")
            } actions: {
                openSettingsButton
            }
        } else if store.isLoaded && candidates.isEmpty {
            ContentUnavailableView {
                Label("No saved restaurants yet", systemImage: "fork.knife")
            } description: {
                Text("Add a shared Google Maps list link or import your Google Takeout in the Settings tab.")
            }
        } else if locationProvider.location == nil {
            ProgressView("Finding your location…")
                .onAppear { locationProvider.requestPermissionIfNeeded() }
        } else {
            suggestionContent
        }
    }

    private var suggestionContent: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 12) {
                    // Scrolls with the content (not pinned); still the first
                    // thing on the page, like the Michelin tab's filters.
                    TravelBudgetPanel(page: .tonight, distanceOnly: uberEatsMode)
                        .padding(.top, 4)
                    if let suggestion = engine.current, !(engine.isSearching && searchIsSlow) {
                        RestaurantCard(suggestion: suggestion, showUberEatsButton: uberEatsMode)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.setHidden(true, id: suggestion.restaurant.id)
                                    // Replace the card right away: nothing
                                    // else watches candidate membership, and
                                    // a card the user just hid must not
                                    // linger until the next manual refresh
                                    // or tab return.
                                    revalidate()
                                } label: {
                                    Label("Hide this restaurant", systemImage: "eye.slash")
                                }
                            }
                    } else if engine.isSearching {
                        // Illustrated placeholder, not a bare spinner — Uber
                        // checks especially run for seconds and a blank page
                        // (or a stale card) reads as a freeze.
                        LoadingCard(message: uberEatsMode ? "Checking Uber Eats availability…"
                                                          : "Checking drive times…")
                    }
                    if let message = engine.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
            }

            Button {
                refreshTask = Task { await refresh() }
            } label: {
                Label(engine.current == nil ? "Suggest a place" : "Not feeling it — another",
                      systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isSearching)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task(id: autoSuggestKey) {
            if engine.current == nil, !engine.isSearching, locationProvider.location != nil {
                await refresh()
            }
        }
        // onChange (not .task(id:)): only actual constraint changes react.
        // A task would also re-fire on every tab return. Revalidate, don't
        // blind-roll: a card that still fits the new budget stays (its
        // traffic minutes refresh); only a fallen-out card is replaced.
        .onChange(of: effectiveBudget) { _, _ in
            revalidate()
        }
        .onChange(of: engine.isSearching) { _, searching in
            if searching {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if engine.isSearching { searchIsSlow = true }
                }
            } else {
                searchIsSlow = false
            }
        }
        .onAppear { revalidate() }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { revalidate() }
        }
    }

    /// Delivery only cares how far away the kitchen is — the Uber Eats tab
    /// always runs on the distance budget, whatever mode the other tabs use.
    private var effectiveBudget: TravelBudget {
        uberEatsMode ? TravelBudget(mode: .distance, value: settings.uberDistanceMeters)
                     : settings.tonightBudget.travelBudget
    }

    /// Re-runs the auto-suggest when data/location first become available.
    private var autoSuggestKey: String {
        "\(candidates.count)-\(locationProvider.location != nil)"
    }

    /// Tab appearance / foreground return: re-check the current card
    /// against the travel budget in current traffic and (Uber) open hours
    /// — stores open while you browse Michelin and decide not to go out.
    /// Cheap when caches are fresh; the card survives whenever it still
    /// fits, so suggestions stay stable across casual tab switches.
    private func revalidate() {
        guard engine.current != nil, !engine.isSearching,
              let origin = locationProvider.location else { return }
        configureEngine(origin: origin)
        Task {
            await engine.revalidateCurrent(candidates: candidates, origin: origin,
                                           budget: effectiveBudget)
        }
    }

    private func refresh() async {
        guard let origin = locationProvider.location else { return }
        configureEngine(origin: origin)
        await engine.refreshSuggestion(candidates: candidates,
                                       origin: origin,
                                       budget: effectiveBudget)
    }

    private func configureEngine(origin: CLLocation) {
        // Uber tab: distance mode never calls MapKit, so the budget gates
        // only the slow WebView availability checks (seconds each). 25 per
        // refresh bounds the worst case — a first scan of a dense area with
        // nothing orderable used to run unbounded, minutes of network for
        // one press. A paused scan is honest, not a give-up: the engine
        // requeues where it stopped, says "refresh to keep looking", and
        // the next press resumes mid-queue. Free skips (quickReject on the
        // week-long notFound cooldowns) never count, so re-walks stay cheap
        // and the tab still can't falsely claim "no results" (the historic
        // bug was a tiny cap WITH cooldowns counted against it).
        engine.maxETAChecksPerRefresh = uberEatsMode ? 25 : 12
        // Fresh verified "not on Uber Eats" places are skipped for free —
        // NOT via availabilityCheck, which counts against the 25-check
        // budget (a neighborhood of them used to exhaust it and show "no
        // results" while orderable places sat further down the queue).
        engine.quickReject = uberEatsMode ? { UberEatsChecker.isInNotFoundCooldown($0) } : nil
        engine.availabilityCheck = uberEatsMode ? { [weak store] restaurant in
            let result = await UberEatsChecker.shared.availability(for: restaurant, near: origin)
            switch result {
            case .available(let storeURL):
                if let storeURL { store?.setUberEatsURL(id: restaurant.id, url: storeURL) }
                return true
            case .closedNow(let storeURL, _):
                // Exists but not accepting orders right now — keep the URL
                // (existence is durable), skip the suggestion (tapping
                // through to Uber's "closed" page is the exact annoyance
                // this avoids). No notFound cooldown: it reopens today.
                if let storeURL { store?.setUberEatsURL(id: restaurant.id, url: storeURL) }
                return false
            case .notFound:
                // Verified absence: persist so the next week of sessions
                // skips the slow WebView check. `unknown` (bot wall) is
                // deliberately NOT persisted — it says nothing about the
                // restaurant.
                store?.setUberEatsNotFound(id: restaurant.id)
                return false
            case .unknown:
                // Stays in: better a search-link button than an empty tab
                // when Uber's bot wall blocks the check.
                return true
            }
        } : nil
    }

    @ViewBuilder
    private var openSettingsButton: some View {
        #if os(iOS)
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        #else
        EmptyView()
        #endif
    }
}
