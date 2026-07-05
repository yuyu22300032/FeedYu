import SwiftUI

@main
struct DinePickApp: App {
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
    }

    private func bootstrap() async {
        await store.load()
        locationProvider.requestPermissionIfNeeded()
        // Michelin first: bundled data means the Michelin tab works instantly.
        await store.sync(MichelinDataSource())
        for source in settings.sharedListSources {
            await store.sync(source)
        }
    }
}
