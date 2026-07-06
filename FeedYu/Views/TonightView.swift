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
    @StateObject private var engine = SuggestionEngine()

    /// The user's own saved places (not the whole Michelin dataset), drawn
    /// only from lists that are currently enabled in Settings. Membership is
    /// tracked by which sources have stamped the place (lastSeenInSourceAt).
    private var candidates: [Restaurant] {
        let enabledSourceIDs = settings.enabledListSourceIDs
        return store.restaurants.filter { restaurant in
            guard !restaurant.isHidden, restaurant.coordinate != nil else { return false }
            if restaurant.addedManually { return true }
            return restaurant.lastSeenInSourceAt.keys.contains { enabledSourceIDs.contains($0) }
        }
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
                    TravelBudgetPanel(distanceOnly: uberEatsMode)
                        .padding(.top, 4)
                    if let suggestion = engine.current {
                        RestaurantCard(suggestion: suggestion, showUberEatsButton: uberEatsMode)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.setHidden(true, id: suggestion.restaurant.id)
                                } label: {
                                    Label("Hide this restaurant", systemImage: "eye.slash")
                                }
                            }
                    } else if engine.isSearching {
                        ProgressView("Checking drive times…")
                            .padding(.top, 80)
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
                Task { await refresh() }
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
        // onChange (not .task(id:)): only actual constraint changes re-suggest.
        // A task would also re-fire on every tab return and replace the card.
        .onChange(of: effectiveBudget) { _, _ in
            if engine.current != nil, !engine.isSearching, locationProvider.location != nil {
                Task { await refresh() }
            }
        }
    }

    /// Delivery only cares how far away the kitchen is — the Uber Eats tab
    /// always runs on the distance budget, whatever mode the other tabs use.
    private var effectiveBudget: TravelBudget {
        uberEatsMode ? TravelBudget(mode: .distance, value: settings.distanceBudgetMeters)
                     : settings.travelBudget
    }

    /// Re-runs the auto-suggest when data/location first become available.
    private var autoSuggestKey: String {
        "\(candidates.count)-\(locationProvider.location != nil)"
    }

    private func refresh() async {
        guard let origin = locationProvider.location else { return }
        engine.availabilityCheck = uberEatsMode ? { [weak store] restaurant in
            let result = await UberEatsChecker.shared.availability(for: restaurant, near: origin)
            if case .available(let storeURL) = result, let storeURL {
                store?.setUberEatsURL(id: restaurant.id, url: storeURL)
            }
            // unknown stays in: better a search-link button than an empty tab
            // when Uber's bot wall blocks the check.
            return result != .notFound
        } : nil
        await engine.refreshSuggestion(candidates: candidates,
                                       origin: origin,
                                       budget: effectiveBudget)
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
