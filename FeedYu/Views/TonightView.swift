import SwiftUI
import CoreLocation

/// Main screen: opens straight to one suggestion from the user's saved places,
/// reachable within the drive-time budget in current traffic.
struct TonightView: View {
    @EnvironmentObject private var store: RestaurantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var locationProvider: LocationProvider
    @StateObject private var engine = SuggestionEngine()

    /// The user's own saved places (not the whole Michelin dataset).
    private var candidates: [Restaurant] {
        store.restaurants.filter {
            !$0.isHidden && (!$0.lists.isEmpty || $0.addedManually) && $0.coordinate != nil
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Tonight")
        }
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
                    if let suggestion = engine.current {
                        RestaurantCard(suggestion: suggestion)
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
    }

    /// Re-runs the auto-suggest when data/location first become available.
    private var autoSuggestKey: String {
        "\(candidates.count)-\(locationProvider.location != nil)"
    }

    private func refresh() async {
        guard let origin = locationProvider.location else { return }
        await engine.refreshSuggestion(candidates: candidates,
                                       origin: origin,
                                       budgetMinutes: settings.driveBudgetMinutes)
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
