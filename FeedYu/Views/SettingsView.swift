import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: RestaurantStore
    @EnvironmentObject private var settings: AppSettings

    @State private var newListURL = ""
    @State private var newListKind: ListKind = .wantToGo
    @State private var newListLabel = ""

    @State private var showingJSONImporter = false
    @State private var showingCSVImporter = false
    @State private var csvImportKind: ListKind = .wantToGo
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                budgetSection
                sharedListsSection
                takeoutSection
                michelinSection
                restaurantsSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $settings.languageChoice) {
                Text("System default").tag("system")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "繁體中文").tag("zh-Hant")
                Text(verbatim: "日本語").tag("ja")
            }
            if settings.languageRestartNeeded {
                Button(role: .destructive) {
                    exit(0) // deliberate: applying AppleLanguages needs a relaunch
                } label: {
                    Label("Quit app now to apply", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Takes effect after the app restarts. Restaurant names from your Google lists follow this language — run Sync now afterwards to re-fetch them.")
        }
    }

    // MARK: - Drive-time budget

    private enum BudgetChoice: Hashable { case thirty, sixty, custom }

    private var budgetChoice: Binding<BudgetChoice> {
        Binding {
            switch settings.driveBudgetMinutes {
            case 30: return .thirty
            case 60: return .sixty
            default: return .custom
            }
        } set: { choice in
            switch choice {
            case .thirty: settings.driveBudgetMinutes = 30
            case .sixty: settings.driveBudgetMinutes = 60
            case .custom: break // keep current value, stepper takes over
            }
        }
    }

    private var budgetSection: some View {
        Section("Drive-time budget") {
            Picker("Budget", selection: budgetChoice) {
                Text("30 min").tag(BudgetChoice.thirty)
                Text("60 min").tag(BudgetChoice.sixty)
                Text("Custom").tag(BudgetChoice.custom)
            }
            .pickerStyle(.segmented)
            if budgetChoice.wrappedValue == .custom {
                Stepper("\(settings.driveBudgetMinutes) minutes",
                        value: $settings.driveBudgetMinutes, in: 15...90, step: 5)
            }
        }
    }

    // MARK: - Shared Google Maps lists

    private var sharedListsSection: some View {
        Section {
            ForEach($settings.sharedLists) { $config in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(config.label.isEmpty ? "Shared list" : config.label)
                            .font(.body.weight(.medium))
                        Spacer()
                        if store.syncingSourceIDs.contains(config.sourceID) {
                            ProgressView()
                        } else {
                            Button("Sync now") {
                                Task { await store.sync(GoogleSharedListSource(config: config)) }
                            }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                        }
                    }
                    Text(config.urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Picker("Counts as", selection: $config.kind) {
                        Text("Want to go").tag(ListKind.wantToGo)
                        Text("Custom list").tag(ListKind.custom)
                    }
                    .font(.footnote)
                    syncStatusLine(for: config.sourceID)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    store.clearSyncStatus(sourceID: settings.sharedLists[index].sourceID)
                }
                settings.sharedLists.remove(atOffsets: offsets)
            }

            // Each control on its own Form row — a Button sharing a row with
            // a Picker gets its taps swallowed by the picker's row-wide target.
            TextField("Paste a maps.app.goo.gl share link", text: $newListURL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Label (optional)", text: $newListLabel)
            Picker("Counts as", selection: $newListKind) {
                Text("Want to go").tag(ListKind.wantToGo)
                Text("Custom list").tag(ListKind.custom)
            }
            Button {
                addSharedList()
            } label: {
                Label("Add list", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(newListURL.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Google Maps shared lists")
        } footer: {
            Text("In Google Maps: your list → Share → copy the link. Starred places can't be shared — import them via Takeout below. If Google changes their page format, sync fails here but the app keeps your last data.")
        }
    }

    private func addSharedList() {
        var config = SharedListConfig(urlString: newListURL.trimmingCharacters(in: .whitespacesAndNewlines))
        config.kind = newListKind
        config.label = newListLabel.trimmingCharacters(in: .whitespaces)
        settings.sharedLists.append(config)
        newListURL = ""
        newListLabel = ""
        Task { await store.sync(GoogleSharedListSource(config: config)) }
    }

    // MARK: - Takeout import

    private var takeoutSection: some View {
        Section {
            Button {
                showingJSONImporter = true
            } label: {
                Label("Import Saved Places.json (Starred)", systemImage: "star")
            }
            // Each importer sits on its own view — two .fileImporter modifiers
            // on the same node silently break in SwiftUI.
            .fileImporter(isPresented: $showingJSONImporter,
                          allowedContentTypes: [.json]) { result in
                handleImport(result: result, isCSV: false)
            }
            Picker("List type for CSV", selection: $csvImportKind) {
                Text("Want to go").tag(ListKind.wantToGo)
                Text("Custom list").tag(ListKind.custom)
            }
            Button {
                showingCSVImporter = true
            } label: {
                Label("Import a list CSV (Want to go…)", systemImage: "doc.text")
            }
            .fileImporter(isPresented: $showingCSVImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                handleImport(result: result, isCSV: true)
            }
            if let importMessage {
                Text(importMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            syncStatusLine(for: "takeout-starred")
        } header: {
            Text("Google Takeout import")
        } footer: {
            Text("takeout.google.com → deselect all → select “Maps (your places)” and “Saved”. Unzip the archive first, then pick Saved Places.json or a list CSV here. CSV rows have no coordinates — FeedYu resolves them from the place link or by geocoding, which can take a minute.")
        }
    }

    private func handleImport(result: Result<URL, Error>, isCSV: Bool) {
        switch result {
        case .failure(let error):
            importMessage = String(localized: "Import failed: \(error.localizedDescription)")
        case .success(let url):
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importMessage = String(localized: "Couldn't read \(url.lastPathComponent).")
                return
            }
            let source: TakeoutImportSource
            if isCSV {
                let listName = url.deletingPathExtension().lastPathComponent
                source = TakeoutImportSource(payload: .listCSV(data, kind: csvImportKind, listName: listName))
            } else {
                source = TakeoutImportSource(payload: .savedPlacesJSON(data))
            }
            importMessage = String(localized: "Importing \(url.lastPathComponent)…")
            Task {
                await store.sync(source)
                if let status = store.syncStatuses[source.id] {
                    importMessage = status.lastError.map { String(localized: "Import failed: \($0)") }
                        ?? String(localized: "Imported \(status.lastCount ?? 0) places from \(url.lastPathComponent).")
                }
            }
        }
    }

    // MARK: - Michelin data

    private var michelinSection: some View {
        Section {
            LabeledContent("Places in dataset",
                           value: "\(store.restaurants.filter { $0.michelinAward != nil }.count)")
            LabeledContent("Dataset date", value: MichelinDataSource.datasetDateDescription)
            Picker("Restaurant name language", selection: $settings.michelinNameLanguage) {
                Text("Local language").tag("local")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "中文").tag("zh")
                Text(verbatim: "日本語").tag("ja")
            }
            if store.syncingSourceIDs.contains("michelin") {
                HStack { ProgressView(); Text("Refreshing…").foregroundStyle(.secondary) }
            } else {
                Button("Refresh from GitHub now") {
                    Task { await store.sync(MichelinDataSource(forceRemote: true)) }
                }
            }
            syncStatusLine(for: "michelin")
        } header: {
            Text("Michelin data")
        } footer: {
            Text("Stars + Bib Gourmand from the open michelin-my-maps dataset. Auto-refreshes weekly; falls back to the bundled snapshot when offline.")
        }
    }

    // MARK: - Restaurants management

    private var restaurantsSection: some View {
        Section("Your restaurants") {
            NavigationLink {
                ManageRestaurantsView()
            } label: {
                Label("Manage & add restaurants", systemImage: "list.bullet.rectangle")
            }
            let hiddenCount = store.restaurants.filter(\.isHidden).count
            if hiddenCount > 0 {
                Text("\(hiddenCount) hidden")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func syncStatusLine(for sourceID: String) -> some View {
        if let status = store.syncStatuses[sourceID] {
            VStack(alignment: .leading, spacing: 2) {
                if let success = status.lastSuccess {
                    Text("Last sync: \(success.formatted(date: .abbreviated, time: .shortened)) · \(status.lastCount ?? 0) places")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error = status.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
