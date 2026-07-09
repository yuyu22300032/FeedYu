import SwiftUI

/// First-launch walkthrough (and Settings → "How to use FeedYu"): what the
/// app does, how to hand it a Google Maps list, and the three things worth
/// knowing. Three pages, page-style TabView — same swipe language as the
/// app itself.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

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
        pageLayout(icon: "fork.knife.circle.fill",
                   title: "Welcome to FeedYu") {
            Text("Tonight's pick — from your own saved restaurants, close enough to actually go.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var importLists: some View {
        pageLayout(icon: "square.and.arrow.up.circle.fill",
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
        pageLayout(icon: "slider.horizontal.3",
                   title: "How it works") {
            VStack(alignment: .leading, spacing: 14) {
                bullet("figure.walk", "Set how far you'll go — walk, drive, or distance")
                bullet("arrow.clockwise", "Not feeling the pick? Tap for another")
                bullet("star.circle", "No lists yet? The Michelin tab works instantly")
            }
        }
    }

    private func pageLayout(icon: String, title: LocalizedStringKey,
                            @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
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
