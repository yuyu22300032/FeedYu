import SwiftUI

/// Card-shaped "working on it" state for the suggestion area: the loading
/// illustration where the photo will be, plus a live progress line. Shown
/// while the engine is checking drive times / Uber Eats availability
/// (seconds-long, WebView-rendered in the Uber case) so a slow search reads
/// as loading, not as a frozen app.
struct LoadingCard: View {
    /// Localized status line, e.g. "Checking drive times…".
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 14) {
            Image("LoadingCover")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                ProgressView()
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        // Same white box as RestaurantCard so the card "arrives" in place.
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
