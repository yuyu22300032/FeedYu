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
                importFriendList.tag(2)
                howItWorks.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 3 {
                    withAnimation { page += 1 }
                } else {
                    dismiss()
                }
            } label: {
                Text(page < 3 ? "Continue" : "Get started")
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
            VStack(alignment: .leading, spacing: 12) {
                bullet("1.circle.fill", "In Google Maps, tap You at the bottom")
                bullet("2.circle.fill", "Find your list and tap its ⋯ button")
                bullet("3.circle.fill", "Choose Share list, then FeedYu")
                bullet("4.circle.fill", "FeedYu imports it the next time it opens")
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

    private var importFriendList: some View {
        pageLayout(vignette: { MiniFriendShare() },
                   title: "Import a friend's list") {
            VStack(alignment: .leading, spacing: 14) {
                bullet("1.circle.fill", "A friend sends their list link in a chat")
                bullet("2.circle.fill", "Press and hold the link")
                bullet("3.circle.fill", "Share it to FeedYu — done")
            }
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

/// Page 1: the core loop acted out — a suggestion card, a tap on its
/// photo, and the Google-Maps-ish place page it opens (details + a
/// navigate button). Loops; Reduce Motion shows the card statically.
private struct MiniSuggestionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = card · 1 = tapping the photo · 2 = the place page in Maps.
    @State private var phase = 0
    @State private var pulse = false

    var body: some View {
        ZStack {
            card
                .opacity(phase == 2 ? 0 : 1)
            mapsPlacePage
                .opacity(phase == 2 ? 1 : 0)
                .scaleEffect(phase == 2 ? 1 : 0.94)
        }
        .frame(width: 210)
        .task {
            guard !reduceMotion else { return } // static: the card itself
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.35)) { phase = 0 }
                pulse = false
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                phase = 1 // tap ring on the photo
                withAnimation(.easeOut(duration: 0.7)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                pulse = false
                withAnimation(.spring(duration: 0.45)) { phase = 2 }
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled else { return }
            }
        }
    }

    private var card: some View {
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
                .overlay {
                    if phase == 1 {
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 3)
                            .frame(width: 30, height: 30)
                            .scaleEffect(pulse ? 2.0 : 0.9)
                            .opacity(pulse ? 0 : 1)
                    }
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    /// The place page the tap lands on: map with the pin, name, rating,
    /// and the directions button ready to navigate.
    private var mapsPlacePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.14))
                .frame(height: 64)
                .overlay(Image(systemName: "mappin.and.ellipse")
                    .font(.title3).foregroundStyle(.red.opacity(0.8)))
            Capsule().fill(Color.primary.opacity(0.75)).frame(width: 110, height: 10)
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: index < 4 ? "star.fill" : "star.leadinghalf.filled")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                }
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 34, height: 6)
            }
            HStack(spacing: 6) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 24)
                    .overlay(HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        Capsule().fill(.white.opacity(0.8)).frame(width: 26, height: 5)
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.white))
                Circle().fill(Color.secondary.opacity(0.2)).frame(width: 24, height: 24)
                    .overlay(Image(systemName: "phone.fill")
                        .font(.system(size: 10)).foregroundStyle(.secondary))
                Circle().fill(Color.secondary.opacity(0.2)).frame(width: 24, height: 24)
                    .overlay(Image(systemName: "bookmark.fill")
                        .font(.system(size: 10)).foregroundStyle(.secondary))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// Page 2: the real Google Maps flow acted out in phases — Maps home
/// with a tap on the "You" tab, the saved-lists screen with a tap on a
/// list's ⋯ button, its menu with a tap on Share, then the share sheet
/// with FeedYu pulsing. Loops; Reduce Motion shows the final frame.
private struct MiniShareSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = Maps home (tap You) · 1 = lists (tap ⋯) · 2 = menu (tap Share)
    /// · 3 = share sheet + FeedYu pulse.
    @State private var phase = 3
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if phase == 0 {
                mapsHome
            } else {
                savedLists
            }
            if phase == 2 {
                listMenu
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 30)
                    .padding(.trailing, 10)
            }
            shareSheet
                .offset(y: phase == 3 ? 0 : 130)
        }
        .frame(width: 210, height: 170)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            guard !reduceMotion else { return } // static: sheet up, no loop
            while !Task.isCancelled {
                await step(to: 0, holdMilliseconds: 1400) // home, tap You
                await step(to: 1, holdMilliseconds: 1500) // lists, tap ⋯
                await step(to: 2, holdMilliseconds: 1400) // menu, tap Share
                guard !Task.isCancelled else { return }
                pulse = false
                withAnimation(.spring(duration: 0.45)) { phase = 3 }
                withAnimation(.easeOut(duration: 1.2).delay(0.3)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func step(to newPhase: Int, holdMilliseconds: Int) async {
        guard !Task.isCancelled else { return }
        pulse = false
        withAnimation(.easeInOut(duration: 0.3)) { phase = newPhase }
        withAnimation(.easeOut(duration: 0.7).delay(0.4)) { pulse = true }
        try? await Task.sleep(for: .milliseconds(holdMilliseconds))
    }

    /// A pulsing ring marking the thing being tapped in `activePhase`.
    @ViewBuilder
    private func tapRing(_ activePhase: Int) -> some View {
        if phase == activePhase {
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                .scaleEffect(pulse ? 1.9 : 0.9)
                .opacity(pulse ? 0 : 1)
        }
    }

    // Phase 0 — Maps home: search bar, map, bottom bar ending in "You".
    private var mapsHome: some View {
        VStack(spacing: 6) {
            Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 14)
                .padding(.horizontal, 10).padding(.top, 10)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.12))
                .overlay(Image(systemName: "mappin.and.ellipse")
                    .font(.title3).foregroundStyle(.red.opacity(0.7)))
                .padding(.horizontal, 10)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "bookmark").foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .overlay(tapRing(0))
            }
            .font(.footnote)
            .padding(.horizontal, 26)
            .padding(.bottom, 10)
        }
    }

    // Phases 1–3 — the saved-lists screen; each row carries a ⋯ button.
    private var savedLists: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(Color.primary.opacity(0.7)).frame(width: 60, height: 9)
            listRow(heart: true, showRing: true)
            listRow(heart: false, showRing: false)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(heart: Bool, showRing: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: heart ? "heart.fill" : "flag.fill")
                .font(.caption)
                .foregroundStyle(heart ? .red : .green)
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 66, height: 8)
            Spacer()
            Image(systemName: "ellipsis")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(4)
                .overlay { if showRing { tapRing(1) } }
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // Phase 2 — the list's ⋯ menu, Share row highlighted.
    private var listMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 44, height: 6)
            }
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.accentColor)
                    .overlay(tapRing(2))
                Capsule().fill(Color.accentColor.opacity(0.4)).frame(width: 52, height: 6)
            }
            HStack(spacing: 6) {
                Image(systemName: "trash").font(.caption2).foregroundStyle(.secondary)
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 38, height: 6)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }

    // Phase 3 — the system share sheet with FeedYu as the pick.
    private var shareSheet: some View {
        SystemShareSheetMock(ringVisible: phase == 3, pulse: pulse)
    }
}

/// The system share sheet in miniature, FeedYu pulsing as the pick —
/// shared by the two import vignettes.
private struct SystemShareSheetMock: View {
    var ringVisible: Bool
    var pulse: Bool

    var body: some View {
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
                                if ringVisible {
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
    }
}

/// The friend's-list flow acted out — a chat with a shared Maps link, a
/// press-and-hold on it, the link menu with Share highlighted, then the
/// share sheet with FeedYu. Loops; Reduce Motion shows the final frame.
private struct MiniFriendShare: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = chat · 1 = holding the link · 2 = link menu (tap Share) ·
    /// 3 = share sheet + FeedYu pulse.
    @State private var phase = 3
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            chat
            if phase == 2 {
                linkMenu
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 62)
                    .padding(.leading, 16)
            }
            SystemShareSheetMock(ringVisible: phase == 3, pulse: pulse)
                .offset(y: phase == 3 ? 0 : 130)
        }
        .frame(width: 210, height: 170)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            guard !reduceMotion else { return } // static: sheet up, no loop
            while !Task.isCancelled {
                pulse = false
                withAnimation(.easeInOut(duration: 0.3)) { phase = 0 }
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                phase = 1 // press-and-hold: slow, sustained ring
                withAnimation(.easeInOut(duration: 1.0)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled else { return }
                pulse = false
                withAnimation(.easeInOut(duration: 0.3)) { phase = 2 }
                withAnimation(.easeOut(duration: 0.7).delay(0.4)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { return }
                pulse = false
                withAnimation(.spring(duration: 0.45)) { phase = 3 }
                withAnimation(.easeOut(duration: 1.2).delay(0.3)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled else { return }
            }
        }
    }

    // The chat: an incoming bubble carrying the Maps list link.
    private var chat: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A plain incoming message.
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 90, height: 16)
            // The link bubble (press-and-hold target).
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: 74, height: 7)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if phase == 1 {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 2.1 : 0.9)
                        .opacity(pulse ? 0 : 1)
                }
            }
            // The user's own reply, for chat flavor.
            Capsule()
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 56, height: 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer()
        }
        .padding(12)
    }

    // Phase 2 — the long-press menu on a link, Share highlighted.
    private var linkMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 6)
            }
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.accentColor)
                    .overlay {
                        if phase == 2 {
                            Circle()
                                .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                                .frame(width: 22, height: 22)
                                .scaleEffect(pulse ? 1.9 : 0.9)
                                .opacity(pulse ? 0 : 1)
                        }
                    }
                Capsule().fill(Color.accentColor.opacity(0.4)).frame(width: 50, height: 6)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
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
