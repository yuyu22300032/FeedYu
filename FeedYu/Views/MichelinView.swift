import SwiftUI
import CoreLocation

/// All Michelin starred + Bib Gourmand places within the drive-time budget,
/// with a price-band random suggester and a browsable in-range list.
struct MichelinView: View {
    @EnvironmentObject private var store: RestaurantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var locationProvider: LocationProvider
    @StateObject private var engine = SuggestionEngine()
    @Environment(\.openURL) private var openURL

    /// Empty = any price. Bands 1–4 ($–$$$$).
    @State private var selectedBands: Set<Int> = [1, 2]
    @State private var selectedAwards: Set<MichelinAward> = [.selected, .bibGourmand]
    @State private var includeFormer = false
    @StateObject private var localizer = MichelinNameLocalizer()

    private var michelinInRange: [(restaurant: Restaurant, km: Double)] {
        guard let origin = locationProvider.location else { return [] }
        let radiusMeters = settings.travelBudget.radiusMeters
        return store.restaurants.compactMap { restaurant in
            guard restaurant.michelinAward != nil, !restaurant.isHidden,
                  includeFormer || restaurant.michelinFormer != true,
                  let distance = restaurant.distance(from: origin), distance <= radiusMeters else { return nil }
            return (restaurant, distance / 1000)
        }
        .sorted { $0.km < $1.km }
    }

    private var suggestionCandidates: [Restaurant] {
        michelinInRange.map(\.restaurant).filter { restaurant in
            guard let award = restaurant.michelinAward, selectedAwards.contains(award) else { return false }
            guard !selectedBands.isEmpty else { return true }
            guard let band = restaurant.priceBand else { return false }
            return selectedBands.contains(band)
        }
    }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if locationProvider.isDenied {
            ContentUnavailableView("Location needed", systemImage: "location.slash",
                                   description: Text("Enable location access to see Michelin restaurants within your drive-time budget."))
        } else if locationProvider.location == nil {
            ProgressView("Finding your location…")
                .onAppear { locationProvider.requestPermissionIfNeeded() }
        } else {
            list
        }
    }

    private var autoSuggestKey: String {
        "\(suggestionCandidates.count)-\(locationProvider.location != nil)"
    }

    private var list: some View {
        List {
            // One box: travel constraint + Michelin filters share a section.
            Section {
                TravelBudgetPanel(boxed: false)
                Picker("Guide", selection: $includeFormer) {
                    Text("Current guide").tag(false)
                    Text("Include former").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                priceFilter
                awardFilter
                Button {
                    Task { await suggest() }
                } label: {
                    Label("Suggest a restaurant", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isSearching || suggestionCandidates.isEmpty)
            } footer: {
                if suggestionCandidates.isEmpty {
                    Text("No Michelin places match the filters within \(settings.travelBudget.label).")
                } else {
                    Text("\(suggestionCandidates.count) matching places in range.")
                }
            }

            if engine.isSearching || engine.current != nil || engine.statusMessage != nil {
                Section {
                    if let suggestion = engine.current {
                        // "Suggest a restaurant" above re-rolls; no separate
                        // change-restaurant button needed. Clear row: the
                        // card brings its own white box, same as Tonight.
                        RestaurantCard(suggestion: suggestion)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else if engine.isSearching {
                        HStack {
                            Spacer()
                            ProgressView("Checking drive times…")
                            Spacer()
                        }
                    }
                    if let message = engine.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Within \(settings.travelBudget.label) (\(michelinInRange.count))") {
                ForEach(michelinInRange, id: \.restaurant.id) { entry in
                    row(for: entry.restaurant, km: entry.km)
                }
            }
        }
        // Pull the first section up flush with the top, like the other tabs.
        .contentMargins(.top, 8, for: .scrollContent)
        .task(id: localizationTaskKey) {
            // Fill local-language names for what's on screen, nearest first.
            await localizer.fill(restaurants: michelinInRange.map(\.restaurant),
                                 nameLanguage: settings.michelinNameLanguage,
                                 store: store)
        }
        // First visit: roll a suggestion as if the button were pressed.
        // current != nil guards tab returns (the engine outlives switches).
        .task(id: autoSuggestKey) {
            if engine.current == nil, !engine.isSearching,
               locationProvider.location != nil, !suggestionCandidates.isEmpty {
                await suggest()
            }
        }
    }

    private var localizationTaskKey: String {
        "\(settings.michelinNameLanguage)|\(includeFormer)|\(michelinInRange.count)"
    }

    private var priceFilter: some View {
        HStack(spacing: 8) {
            ForEach(1...4, id: \.self) { band in
                let isOn = selectedBands.contains(band)
                Button {
                    if isOn { selectedBands.remove(band) } else { selectedBands.insert(band) }
                } label: {
                    Text(String(repeating: "$", count: band))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isOn ? Color.green.opacity(0.25) : Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .listRowSeparator(.hidden)
        .accessibilityLabel("Price bands — none selected means any price")
    }

    private var awardFilter: some View {
        HStack(spacing: 8) {
            ForEach(MichelinAward.allCases) { award in
                let isOn = selectedAwards.contains(award)
                Button {
                    if isOn { selectedAwards.remove(award) } else { selectedAwards.insert(award) }
                } label: {
                    Text(shortLabel(for: award))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isOn ? Color.red.opacity(0.2) : Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .listRowSeparator(.hidden)
    }

    private func shortLabel(for award: MichelinAward) -> String {
        switch award {
        case .selected: return String(localized: "Selected")
        case .bibGourmand: return String(localized: "Bib")
        case .oneStar: return "⭐️"
        case .twoStars: return "⭐️⭐️"
        case .threeStars: return "⭐️⭐️⭐️"
        }
    }

    private func row(for restaurant: Restaurant, km: Double) -> some View {
        Button {
            openURL(GoogleMapsOpener.url(for: restaurant))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(restaurant.displayName(nameLanguage: settings.michelinNameLanguage))
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(String(format: String(localized: "%.1f km"), km))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let award = restaurant.michelinAward {
                        Text(award.badge).font(.caption)
                    }
                    if restaurant.michelinFormer == true, let years = restaurant.michelinYears {
                        Text(String(localized: "Former: \(years)"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let price = restaurant.priceLabel {
                        Text(price).font(.caption).foregroundStyle(.green)
                    }
                    if let cuisine = restaurant.cuisine {
                        Text(cuisine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.setHidden(true, id: restaurant.id)
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
    }

    private func suggest() async {
        guard let origin = locationProvider.location else { return }
        await engine.refreshSuggestion(candidates: suggestionCandidates,
                                       origin: origin,
                                       budget: settings.travelBudget)
    }
}
