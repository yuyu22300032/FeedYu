import SwiftUI

struct RestaurantCard: View {
    let suggestion: Suggestion
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settings: AppSettings

    private var restaurant: Restaurant { suggestion.restaurant }

    private var displayName: String {
        restaurant.displayName(nameLanguage: settings.michelinNameLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Image(systemName: "car.fill")
                if let eta = suggestion.etaMinutes {
                    Text("\(eta) min in current traffic")
                } else {
                    Text(String(format: String(localized: "%.1f km away (straight line)"), suggestion.straightLineKm))
                }
            }
            .font(.subheadline.weight(.medium))

            if let summary = restaurant.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Button {
                openURL(GoogleMapsOpener.url(for: restaurant))
            } label: {
                Label("Open in Google Maps — check hours & traffic", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
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
            ForEach(Array(restaurant.lists).sorted { $0.rawValue < $1.rawValue }) { kind in
                BadgeChip(text: kind.label, tint: .blue, systemImage: kind.systemImage)
            }
        }
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
