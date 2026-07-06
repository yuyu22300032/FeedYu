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

    var body: some View {
        TabView {
            TonightView()
                .tabItem { Label("Tonight", systemImage: "fork.knife") }
            MichelinView()
                .tabItem { Label("Michelin", systemImage: "star.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
