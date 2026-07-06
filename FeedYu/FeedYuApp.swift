import SwiftUI

@main
struct FeedYuApp: App {
    @StateObject private var store = RestaurantStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var locationProvider = LocationProvider()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(locationProvider)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: RestaurantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var locationProvider: LocationProvider
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareInboxMessage: String?

    private enum Tab: Int, CaseIterable, Identifiable {
        case tonight, michelin, uberEats, settings

        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .tonight: return "Tonight"
            case .michelin: return "Michelin"
            case .uberEats: return "Uber Eats"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .tonight: return "fork.knife"
            case .michelin: return "star.circle"
            case .uberEats: return "takeoutbag.and.cup.and.straw"
            case .settings: return "gearshape"
            }
        }
    }
    @State private var selectedTab: Tab = .tonight

    var body: some View {
        // Page-style TabView + custom bar: the page style is what makes
        // horizontal swiping between tabs actually work (a plain gesture on
        // a standard TabView never fires — Lists swallow the drag first).
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                TonightView().tag(Tab.tonight)
                MichelinView().tag(Tab.michelin)
                TonightView(uberEatsMode: true).tag(Tab.uberEats)
                SettingsView().tag(Tab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            tabBar
        }
        .task { await bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { drainShareInbox() }
        }
        .alert("Shared lists", isPresented: Binding(
            get: { shareInboxMessage != nil },
            set: { if !$0 { shareInboxMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareInboxMessage ?? "")
        }
    }

    private var tabBar: some View {
        HStack {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation { selectedTab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .regular))
                        Text(tab.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .background(.bar)
    }

    /// Links dropped off by the share extension become shared-list configs.
    private func drainShareInbox() {
        let pending = ShareInbox.drain()
        guard !pending.isEmpty else { return }
        var added = 0
        for urlString in pending {
            guard !settings.sharedLists.contains(where: { $0.urlString == urlString }) else { continue }
            guard settings.canAddList else {
                shareInboxMessage = String(localized: "You've reached \(AppSettings.maxLists) lists — delete one in Settings, then share the link again.")
                return
            }
            let config = SharedListConfig(urlString: urlString)
            settings.sharedLists.append(config)
            added += 1
            Task { await store.sync(GoogleSharedListSource(config: config)) }
        }
        if added > 0 {
            shareInboxMessage = String(localized: "Added \(added) shared list(s) — syncing now. Name and manage them in Settings.")
        }
    }

    private func bootstrap() async {
        await store.load()
        drainShareInbox()
        // Takeout imports done before the list registry existed get registered
        // so their places keep feeding Tonight.
        settings.registerLegacyImports(from: store.restaurants)
        locationProvider.requestPermissionIfNeeded()
        // Michelin first: bundled data means the Michelin tab works instantly.
        await store.sync(MichelinDataSource())
        // Disabled lists are skipped (no point scraping a list that's off);
        // they re-sync when toggled back on or via Sync now.
        for source in settings.sharedListSources where source.config.isEnabled {
            await store.sync(source)
        }
    }
}
