import SwiftUI

struct RestaurantCard: View {
    let suggestion: Suggestion
    /// Uber Eats tab: adds an order button (exact store page when the
    /// availability check captured it, else a search universal link).
    var showUberEatsButton = false
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RestaurantStore
    @State private var fetchedInfo: PlaceInfoFetcher.PlaceInfo?

    private var restaurant: Restaurant { suggestion.restaurant }

    private var displayName: String {
        restaurant.displayName(nameLanguage: settings.michelinNameLanguage)
    }

    private var coverImageURL: URL? {
        // Filter here too: generic Google artwork may have been persisted by
        // fetches done before the isGenericImage guard existed.
        let url = fetchedInfo?.imageURL ?? restaurant.imageURL
        return url.flatMap { PlaceInfoFetcher.isGenericImage($0) ? nil : $0 }
    }
    private var summaryText: String? { fetchedInfo?.summary ?? restaurant.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            coverImage

            badgeRow

            Text(displayName)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            if displayName != restaurant.name {
                Text(restaurant.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let years = restaurant.michelinYears {
                Label(String(localized: "On the Michelin list: \(years)"), systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(restaurant.michelinFormer == true ? .orange : .secondary)
            }

            if let cuisine = restaurant.cuisine {
                Text(cuisine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let address = restaurant.address {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Image(systemName: suggestion.travelMode.systemImage)
                if let eta = suggestion.etaMinutes {
                    if suggestion.travelMode == .walking {
                        Text("\(eta) min on foot")
                    } else {
                        Text("\(eta) min in current traffic")
                    }
                } else {
                    Text(String(format: String(localized: "%.1f km away (straight line)"), suggestion.straightLineKm))
                }
            }
            .font(.subheadline.weight(.medium))

            // Always rendered with reserved space so cards keep one height
            // whether or not a description was found.
            Text(summaryText ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4, reservesSpace: true)

            if showUberEatsButton {
                Button {
                    // Live store lookup: the suggestion snapshot was taken
                    // BEFORE the availability check persisted the store URL.
                    openURL(liveUberEatsURL ?? UberEatsChecker.searchURL(for: restaurant.name))
                } label: {
                    Label("Order on Uber Eats", systemImage: "takeoutbag.and.cup.and.straw.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if let michelinURL = restaurant.michelinURL {
                Button {
                    openURL(MichelinDataSource.localizedGuideURL(michelinURL))
                } label: {
                    Label("View in Michelin Guide", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Grouped-style white box (thinMaterial vanished on gray pages).
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .task(id: restaurant.id) {
            fetchedInfo = PlaceInfoFetcher.PlaceInfo(summary: restaurant.summary,
                                                     imageURL: restaurant.imageURL)
            fetchedInfo = await PlaceInfoFetcher.shared.info(for: restaurant, store: store)
        }
    }

    /// Always the same 180 pt frame so every card lines up; a fork stands in
    /// when there's no photo (or it fails to load). Tapping it opens the
    /// place in Google Maps (it replaced the old open-in-maps button — the
    /// corner badge is the affordance).
    private var coverImage: some View {
        Button {
            // Live row, not the suggestion snapshot — a cid resolved after
            // the card appeared upgrades this tap (same trap as Uber's URL).
            // If none resolved yet, try once more (briefly) before falling
            // back to the search URL.
            Task {
                openURL(await PlaceInfoFetcher.shared.mapsURL(for: liveRestaurant, store: store))
            }
        } label: {
            Group {
                if let coverImageURL {
                    AsyncImage(url: coverImageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            coverPlaceholder
                        default:
                            Color.gray.opacity(0.12)
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .overlay(alignment: .bottomTrailing) {
                Label("Google Maps", systemImage: "arrow.up.right.square.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in Google Maps")
    }

    /// User-saved Google places get the illustrated "no pictures~" cover;
    /// Michelin places (which nearly always have a photo) keep the plain fork.
    @ViewBuilder
    private var coverPlaceholder: some View {
        if restaurant.michelinAward == nil {
            Image("NoPictureCover")
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.12)
                Image(systemName: "fork.knife")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 8) {
            if let award = restaurant.michelinAward {
                BadgeChip(text: award.badge, tint: .red)
            }
            if restaurant.michelinFormer == true {
                BadgeChip(text: String(localized: "Former"), tint: .gray)
            }
            if let price = restaurant.priceLabel {
                BadgeChip(text: price, tint: .green)
            }
            ForEach(listLabels, id: \.self) { label in
                BadgeChip(text: label, tint: .blue, systemImage: "list.bullet")
            }
        }
    }

    private var liveRestaurant: Restaurant {
        store.restaurants.first(where: { $0.id == restaurant.id }) ?? restaurant
    }

    private var liveUberEatsURL: URL? {
        liveRestaurant.uberEatsURL ?? restaurant.uberEatsURL
    }

    /// Labels of the user lists this place belongs to (via source stamps).
    private var listLabels: [String] {
        Array(Set(restaurant.lastSeenInSourceAt.keys.compactMap {
            settings.listLabel(forSourceID: $0)
        })).sorted()
    }
}

struct BadgeChip: View {
    let text: String
    let tint: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}
