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

/// Page 2: the whole gesture acted out in phases — a Google-Maps-ish
/// saved list, a tap on its Share button, the share sheet rising, and
/// FeedYu pulsing as the thing to pick. Loops; Reduce Motion shows the
/// final frame statically.
private struct MiniShareSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = list, 1 = tapping Share, 2 = sheet up + FeedYu pulse.
    @State private var phase = 2
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // The "list" behind the sheet, with a visible Share affordance.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.red)
                    Capsule().fill(Color.primary.opacity(0.7)).frame(width: 70, height: 9)
                    Spacer()
                    // The Share button the tap lands on.
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .overlay {
                            if phase == 1 {
                                Circle()
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                                    .scaleEffect(pulse ? 1.7 : 0.9)
                                    .opacity(pulse ? 0 : 1)
                            }
                        }
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

            // The share sheet (rises in phase 2).
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
                                    if phase == 2 {
                                        Circle()
                                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                                            .frame(width: 34, height: 34)
                                            .scaleEffect(pulse ? 1.5 : 1)
                                            .opacity(pulse ? 0 : 0.9)
                                    }
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
            .offset(y: phase == 2 ? 0 : 130)
        }
        .frame(width: 210, height: 170)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            guard !reduceMotion else { return } // static: sheet up, no loop
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.3)) { phase = 0 }
                pulse = false
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled else { return }
                phase = 1 // tap ring on Share
                withAnimation(.easeOut(duration: 0.7)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                pulse = false
                withAnimation(.spring(duration: 0.45)) { phase = 2 }
                withAnimation(.easeOut(duration: 1.2).delay(0.3)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(2400))
            }
        }
    }
}

/// Page 3: the travel-budget panel in miniature — a finger taps through
/// distance → walk → drive (each tap shown with a ring), and the slider
/// jumps to that mode's own value. Loops; Reduce Motion shows drive
/// statically.
private struct MiniBudgetPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let symbols = ["ruler", "figure.walk", "car.fill"]
    private static let sliderTargets: [CGFloat] = [0.35, 0.55, 0.75]
    @State private var activeMode = 2
    @State private var tappingMode: Int?
    @State private var tapPulse = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(activeMode == index ? Color.accentColor.opacity(0.18)
                                                  : Color.gray.opacity(0.12))
                        .frame(height: 30)
                        .overlay(Image(systemName: Self.symbols[index])
                            .font(.caption)
                            .foregroundStyle(activeMode == index ? Color.accentColor : Color.secondary))
                        .overlay {
                            if tappingMode == index {
                                Circle()
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                                    .frame(width: 26, height: 26)
                                    .scaleEffect(tapPulse ? 1.8 : 0.9)
                                    .opacity(tapPulse ? 0 : 1)
                            }
                        }
                }
            }
            GeometryReader { geo in
                let position = geo.size.width * Self.sliderTargets[activeMode]
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Color.accentColor).frame(width: position, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: position - 8)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
        }
        .padding(14)
        .frame(width: 210)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .task {
            guard !reduceMotion else { return } // static: drive selected
            while !Task.isCancelled {
                for index in 0..<3 {
                    tappingMode = index
                    tapPulse = false
                    withAnimation(.easeOut(duration: 0.55)) { tapPulse = true }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    tappingMode = nil
                    withAnimation(.easeInOut(duration: 0.5)) { activeMode = index }
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled else { return }
                }
            }
        }
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
