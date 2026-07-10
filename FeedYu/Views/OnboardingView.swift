import SwiftUI

/// First-launch walkthrough (and Settings → "How to use FeedYu"): what the
/// app does, how to hand it a Google Maps list, and the three things worth
/// knowing. Three pages, page-style TabView — same swipe language as the
/// app itself. Each page opens with a drawn vignette (miniature UI, not
/// screenshots: theme-aware, localization-free, license-free).
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    /// `-onboardingPage n` launch argument jumps straight to a page —
    /// screenshot automation can't swipe (see DEVELOPMENT.md).
    @State private var page = UserDefaults.standard.integer(forKey: "onboardingPage")

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                importLists.tag(1)
                howItWorks.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    dismiss()
                }
            } label: {
                Text(page < 2 ? "Continue" : "Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .presentationDragIndicator(.visible)
    }

    private var welcome: some View {
        pageLayout(vignette: { MiniSuggestionCard() },
                   title: "Welcome to FeedYu") {
            Text("Tonight's pick — from your own saved restaurants, close enough to actually go.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var importLists: some View {
        pageLayout(vignette: { MiniShareSheet() },
                   title: "Bring your Google Maps lists") {
            VStack(alignment: .leading, spacing: 14) {
                bullet("1.circle.fill", "In Google Maps, open Saved and pick a list")
                bullet("2.circle.fill", "Tap Share and choose FeedYu")
                bullet("3.circle.fill", "FeedYu imports it the next time it opens")
            }
            Button {
                // LSApplicationQueriesSchemes already whitelists this.
                if let url = URL(string: "comgooglemaps://"),
                   UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                } else if let web = URL(string: "https://www.google.com/maps") {
                    UIApplication.shared.open(web)
                }
            } label: {
                Label("Open Google Maps", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
        }
    }

    private var howItWorks: some View {
        pageLayout(vignette: { MiniBudgetPanel() },
                   title: "How it works") {
            VStack(alignment: .leading, spacing: 14) {
                bullet("figure.walk", "Set how far you'll go — walk, drive, or distance")
                bullet("arrow.clockwise", "Not feeling the pick? Tap for another")
                bullet("star.circle", "No lists yet? The Michelin tab works instantly")
            }
        }
    }

    private func pageLayout(@ViewBuilder vignette: () -> some View,
                            title: LocalizedStringKey,
                            @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 22) {
            Spacer()
            vignette()
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            content()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Vignettes (miniature UI drawn in code)

/// Page 1: a shrunken suggestion card — photo, badges, name, travel line,
/// re-roll pill. Skeleton bars instead of words: nothing to translate.
private struct MiniSuggestionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color.orange.opacity(0.75), Color.red.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 84)
                .overlay(Image(systemName: "fork.knife")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.9)))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(6)
                }
            HStack(spacing: 6) {
                MiniChip(text: "⭐️", tint: .red)
                MiniChip(text: "$$", tint: .green)
            }
            Capsule().fill(Color.primary.opacity(0.75)).frame(width: 110, height: 10)
            HStack(spacing: 6) {
                Image(systemName: "car.fill").font(.caption2).foregroundStyle(.secondary)
                Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 70, height: 7)
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 24)
                .overlay(Image(systemName: "arrow.clockwise")
                    .font(.caption2.bold()).foregroundStyle(.white))
        }
        .padding(14)
        .frame(width: 210)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// Page 2: a Google-Maps-ish list with a share sheet rising over it,
/// FeedYu's icon pulsing as the thing to tap.
private struct MiniShareSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // The "list" behind the sheet.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.red)
                    Capsule().fill(Color.primary.opacity(0.7)).frame(width: 80, height: 9)
                    Spacer()
                }
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 6) {
                        Circle().fill(Color.secondary.opacity(0.3)).frame(width: 14, height: 14)
                        Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 8)
                    }
                }
                Spacer()
            }
            .padding(12)

            // The share sheet.
            VStack(spacing: 8) {
                Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 28, height: 4)
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { index in
                        VStack(spacing: 3) {
                            if index == 1 {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 34, height: 34)
                                    Image(systemName: "fork.knife")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                    Circle()
                                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                                        .frame(width: 34, height: 34)
                                        .scaleEffect(pulse ? 1.5 : 1)
                                        .opacity(pulse ? 0 : 0.9)
                                }
                                Text(verbatim: "FeedYu")
                                    .font(.system(size: 8, weight: .semibold))
                            } else {
                                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 34, height: 34)
                                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 26, height: 5)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground),
                        in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 10, y: -3)
        }
        .frame(width: 210, height: 170)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Page 3: the travel-budget panel in miniature, thumb sweeping the track.
private struct MiniBudgetPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                miniMode("ruler", on: false)
                miniMode("figure.walk", on: false)
                miniMode("car.fill", on: true)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Color.accentColor)
                        .frame(width: sweep ? geo.size.width * 0.7 : geo.size.width * 0.3, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: (sweep ? geo.size.width * 0.7 : geo.size.width * 0.3) - 8)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
        }
        .padding(14)
        .frame(width: 210)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                sweep = true
            }
        }
    }

    private func miniMode(_ symbol: String, on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(on ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
            .frame(height: 30)
            .overlay(Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(on ? Color.accentColor : Color.secondary))
    }
}

private struct MiniChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
