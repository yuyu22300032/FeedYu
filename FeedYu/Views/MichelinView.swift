import SwiftUI
import CoreLocation

/// All Michelin starred + Bib Gourmand places within the drive-time budget,
/// with a price-band random suggester and a browsable in-range list.
struct MichelinView: View {
    @EnvironmentObject private var store: RestaurantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var locationProvider: LocationProvider
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = SuggestionEngine()
    @Environment(\.openURL) private var openURL

    // Price/award filters live in AppSettings (persisted): as plain @State
    // they silently reset to the defaults on every launch. includeFormer
    // stays session-scoped — the current guide is the right opening view.
    @State private var includeFormer = false
    @StateObject private var localizer = MichelinNameLocalizer()
    /// See TonightView.searchIsSlow — after 1 s the loading card takes
    /// over from a stale suggestion so a long search doesn't read as a
    /// frozen app.
    @State private var searchIsSlow = false

    /// Memoized: a body evaluation reads this many times (directly, via
    /// suggestionCandidates, the task keys, the section header), and each
    /// uncached compute is a distance scan + sort over the whole ~20k-row
    /// store — per render, on the main thread. The cache box is a plain
    /// reference in @State so it survives re-renders without triggering any.
    private final class InRangeCache {
        var key: String?
        var value: [(restaurant: Restaurant, km: Double)] = []
    }
    @State private var inRangeCache = InRangeCache()

    private var michelinInRange: [(restaurant: Restaurant, km: Double)] {
        guard let origin = locationProvider.location else { return [] }
        let radiusMeters = settings.michelinBudget.travelBudget.radiusMeters
        let key = "\(store.version)|\(origin.coordinate.latitude)|\(origin.coordinate.longitude)|\(radiusMeters)|\(includeFormer)"
        if inRangeCache.key == key { return inRangeCache.value }
        let result: [(restaurant: Restaurant, km: Double)] = store.restaurants.compactMap { restaurant in
            guard restaurant.michelinAward != nil, !restaurant.isHidden,
                  includeFormer || restaurant.michelinFormer != true,
                  let distance = restaurant.distance(from: origin), distance <= radiusMeters else { return nil }
            return (restaurant, distance / 1000)
        }
        .sorted { $0.km < $1.km }
        inRangeCache.key = key
        inRangeCache.value = result
        return result
    }

    private var suggestionCandidates: [Restaurant] {
        michelinInRange.map(\.restaurant).filter { restaurant in
            guard let award = restaurant.michelinAward, settings.michelinAwards.contains(award) else { return false }
            guard !settings.michelinPriceBands.isEmpty else { return true }
            guard let band = restaurant.priceBand else { return false }
            return settings.michelinPriceBands.contains(band)
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
                TravelBudgetPanel(page: .michelin, boxed: false)
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
                // Empty-state explanation only. No "N matching places in
                // range" count: the radius is a best-case straight-line
                // estimate, and a count reads as "N suggestible" — edge
                // places then fail the real route check and the tab looks
                // broken ("2 match, nothing suggested"). The empty case is
                // safe to state: nothing within the generous bound really
                // does mean nothing reachable.
                if suggestionCandidates.isEmpty {
                    Text("No Michelin places match the filters within \(settings.michelinBudget.travelBudget.label).")
                }
            }

            if engine.isSearching || engine.current != nil || engine.statusMessage != nil {
                Section {
                    if let suggestion = engine.current, !(engine.isSearching && searchIsSlow) {
                        // "Suggest a restaurant" above re-rolls; no separate
                        // change-restaurant button needed. Clear row: the
                        // card brings its own white box, same as Tonight.
                        RestaurantCard(suggestion: suggestion)
                            // Same identity rule as Tonight: replacement
                            // must not inherit the old card's @State (its
                            // late photo fetch put the wrong restaurant's
                            // image on the card).
                            .id(suggestion.id)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else if engine.isSearching {
                        LoadingCard(message: "Checking drive times…")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    if let message = engine.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // prefilterLabel, not label: rows are straight-line-filtered, not
            // route-verified — "Within 15 min walk" here contradicted the
            // suggester whenever the real route exceeded the budget.
            Section("Within \(settings.michelinBudget.travelBudget.prefilterLabel) (\(michelinInRange.count))") {
                ForEach(michelinInRange, id: \.restaurant.id) { entry in
                    row(for: entry.restaurant, km: entry.km)
                }
            }
        }
        // Pull the first section up flush with the top, like the other tabs.
        .contentMargins(.top, 8, for: .scrollContent)
        // Match the Tonight/Uber pages' 12 pt stack spacing — the default
        // grouped-List section gap reads as a hole now that the budget
        // section usually has no footer.
        .listSectionSpacing(12)
        .task(id: localizationTaskKey) {
            // Fill local-language names for what's on screen, nearest first.
            // (No Maps-link pre-warm for rows: each resolution downloads a
            // 1–2 MB search page, and the suggestion card already warms the
            // likely pick — rows resolve on tap instead, saving data.)
            await localizer.fill(restaurants: michelinInRange.map(\.restaurant),
                                 nameLanguage: settings.michelinNameLanguage,
                                 store: store)
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { revalidate() }
        }
        // Adjusting any constraint revalidates immediately, same as
        // Tonight: a card that still satisfies the new budget AND filters
        // stays (filters flow through candidate-set membership); one that
        // doesn't is replaced — and with NO card, a fresh one is rolled
        // (the auto-suggest task id usually changes with the filters, but
        // not when the candidate COUNT happens to stay equal). onChange
        // (not .task(id:)): tab returns must not re-fire.
        .onChange(of: settings.michelinBudget) { _, _ in revalidateOrRoll() }
        .onChange(of: settings.michelinPriceBands) { _, _ in revalidateOrRoll() }
        .onChange(of: settings.michelinAwards) { _, _ in revalidateOrRoll() }
        .onChange(of: includeFormer) { _, _ in revalidateOrRoll() }
        // First visit: roll a suggestion as if the button were pressed.
        // current != nil guards tab returns (the engine outlives switches).
        .task(id: autoSuggestKey) {
            // Same unwind-wait as TonightView: an id change mid-search
            // cancels the old task, and skipping while it unwound left a
            // blank pane. Roll whenever there is no card — gating on a
            // clear statusMessage suppressed recovery rolls after a stale
            // "nothing reachable" once new candidates arrived (Tonight
            // shipped that exact regression).
            while engine.isSearching {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
            }
            if engine.current == nil,
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
                let isOn = settings.michelinPriceBands.contains(band)
                Button {
                    if isOn { settings.michelinPriceBands.remove(band) } else { settings.michelinPriceBands.insert(band) }
                } label: {
                    Text(String(repeating: "$", count: band))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isOn ? Color.green.opacity(0.25) : Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                // Selection is otherwise color-only — VoiceOver and the UI
                // contract tests both need the trait.
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .listRowSeparator(.hidden)
        // A labeled CONTAINER, not a labeled element: a bare
        // .accessibilityLabel on the stack collapses it into one element
        // and swallows the four chip buttons — VoiceOver lost them and so
        // did the UI contract tests.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Price bands — none selected means any price")
    }

    private var awardFilter: some View {
        HStack(spacing: 8) {
            ForEach(MichelinAward.allCases) { award in
                let isOn = settings.michelinAwards.contains(award)
                Button {
                    if isOn { settings.michelinAwards.remove(award) } else { settings.michelinAwards.insert(award) }
                } label: {
                    Text(shortLabel(for: award))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isOn ? Color.red.opacity(0.2) : Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
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
            // Michelin dataset rows carry no cid — resolve one on the fly
            // (briefly, persisted) so the tap lands on the exact place page
            // instead of a search-results list.
            Task {
                openURL(await PlaceInfoFetcher.shared.mapsURL(for: restaurant, store: store))
            }
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
                // If this row is also the current suggestion, replace the
                // card right away — nothing else watches candidate
                // membership until the next tab return.
                revalidate()
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
    }

    private func suggest() async {
        guard let origin = locationProvider.location else { return }
        await engine.refreshSuggestion(candidates: suggestionCandidates,
                                       origin: origin,
                                       budget: settings.michelinBudget.travelBudget)
    }

    /// Constraint changed: revalidate the current card, or — when there is
    /// no card to revalidate — roll a fresh one right away.
    private func revalidateOrRoll() {
        if engine.current == nil {
            guard !engine.isSearching, locationProvider.location != nil,
                  !suggestionCandidates.isEmpty else { return }
            Task { await suggest() }
        } else {
            revalidate()
        }
    }

    /// Tab appearance / foreground return: the current card's drive time
    /// was computed when it was rolled — re-verify it against current
    /// traffic, silently rolling a replacement if it fell out of budget.
    private func revalidate() {
        guard engine.current != nil, !engine.isSearching,
              let origin = locationProvider.location else { return }
        Task {
            await engine.revalidateCurrent(candidates: suggestionCandidates,
                                           origin: origin,
                                           budget: settings.michelinBudget.travelBudget)
        }
    }
}
