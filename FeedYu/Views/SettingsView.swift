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

    /// Rename-list alert state: the sourceID being renamed + draft text.
    @State private var renamingSourceID: String?
    @State private var renameText = ""

    /// Remove-list confirmation state.
    @State private var removalSourceID: String?
    @State private var removalLabel = ""

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                listsSection
                addListSection
                takeoutSection
                michelinSection
                restaurantsSection
            }
            .alert("Rename list", isPresented: Binding(
                get: { renamingSourceID != nil },
                set: { if !$0 { renamingSourceID = nil } }
            )) {
                TextField("List name", text: $renameText)
                Button("Save") { applyRename() }
                Button("Cancel", role: .cancel) { renamingSourceID = nil }
            }
            .confirmationDialog("Remove “\(removalLabel)”?", isPresented: Binding(
                get: { removalSourceID != nil },
                set: { if !$0 { removalSourceID = nil } }
            ), titleVisibility: .visible) {
                Button("Remove list and its places", role: .destructive) { applyRemoval() }
                Button("Cancel", role: .cancel) { removalSourceID = nil }
            } message: {
                Text("Places only on this list are deleted. Places that are also on another list, added manually, or in the Michelin guide are kept.")
            }
        }
    }

    private func beginRemoval(sourceID: String, label: String) {
        removalLabel = label
        removalSourceID = sourceID
    }

    private func applyRemoval() {
        guard let sourceID = removalSourceID else { return }
        removalSourceID = nil
        var otherListIDs = Set(settings.sharedLists.map(\.sourceID))
        otherListIDs.formUnion(settings.importedLists.map(\.sourceID))
        otherListIDs.remove(sourceID)
        store.removeList(sourceID: sourceID, otherListSourceIDs: otherListIDs)
        settings.sharedLists.removeAll { $0.sourceID == sourceID }
        settings.importedLists.removeAll { $0.sourceID == sourceID }
    }

    private func beginRename(sourceID: String, currentLabel: String) {
        renameText = currentLabel
        renamingSourceID = sourceID
    }

    private func applyRename() {
        guard let sourceID = renamingSourceID else { return }
        renamingSourceID = nil
        let label = renameText.trimmingCharacters(in: .whitespaces)
        if let index = settings.sharedLists.firstIndex(where: { $0.sourceID == sourceID }) {
            settings.sharedLists[index].label = label
        } else if let index = settings.importedLists.firstIndex(where: { $0.sourceID == sourceID }), !label.isEmpty {
            settings.importedLists[index].label = label
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

    // MARK: - Your lists (shared links + Takeout imports, each toggleable)

    /// Visible-place count per list source, one pass over the store.
    private var placeCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for restaurant in store.restaurants where !restaurant.isHidden {
            for sourceID in restaurant.lastSeenInSourceAt.keys {
                counts[sourceID, default: 0] += 1
            }
        }
        return counts
    }

    private var listsSection: some View {
        Section {
            ForEach($settings.sharedLists) { $config in
                sharedListRow($config)
            }
            ForEach($settings.importedLists) { $config in
                importedListRow($config)
            }
        } header: {
            Text("Your lists (\(settings.listCount)/\(AppSettings.maxLists))")
        } footer: {
            Text("Each list feeds the Tonight and Uber Eats tabs independently — toggle either off without deleting anything (handy for trying out a friend's list). Removing a list also deletes its places, except ones on another list, added manually, or in the Michelin guide.")
        }
    }

    /// Tonight / Uber Eats enablement as two side-by-side toggle chips —
    /// same pattern as the Michelin price/award filters. (Two switch
    /// Toggles stacked in one Form row overlapped their hit areas/layout;
    /// plain-button chips render reliably inside List rows here.)
    private func tabToggles(tonight: Binding<Bool>, uberEats: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            tabChip(String(localized: "Tonight"), systemImage: "fork.knife", isOn: tonight)
            tabChip(String(localized: "Uber Eats"), systemImage: "takeoutbag.and.cup.and.straw", isOn: uberEats)
        }
    }

    private func tabChip(_ label: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? "checkmark" : systemImage)
                    .font(.caption2.weight(.bold))
                Text(label)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isOn.wrappedValue ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    private func sharedListRow(_ config: Binding<SharedListConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.wrappedValue.label.isEmpty ? String(localized: "Shared list") : config.wrappedValue.label)
                .font(.body.weight(.medium))
            tabToggles(tonight: config.isEnabled, uberEats: config.isEnabledForUberEats)
            Text(config.wrappedValue.urlString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text("\(placeCounts[config.wrappedValue.sourceID] ?? 0) places")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    beginRename(sourceID: config.wrappedValue.sourceID,
                                currentLabel: config.wrappedValue.label)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename list")
                Button {
                    beginRemoval(sourceID: config.wrappedValue.sourceID,
                                 label: config.wrappedValue.label.isEmpty
                                     ? String(localized: "Shared list") : config.wrappedValue.label)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .accessibilityLabel("Remove list")
                if store.syncingSourceIDs.contains(config.wrappedValue.sourceID) {
                    ProgressView()
                } else {
                    Button("Sync now") {
                        Task { await store.sync(GoogleSharedListSource(config: config.wrappedValue)) }
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
            }
            syncStatusLine(for: config.wrappedValue.sourceID)
        }
    }

    private func importedListRow(_ config: Binding<ImportedListConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.wrappedValue.label)
                .font(.body.weight(.medium))
            tabToggles(tonight: config.isEnabled, uberEats: config.isEnabledForUberEats)
            HStack {
                Text("\(placeCounts[config.wrappedValue.sourceID] ?? 0) places")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    beginRename(sourceID: config.wrappedValue.sourceID,
                                currentLabel: config.wrappedValue.label)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename list")
                Button {
                    beginRemoval(sourceID: config.wrappedValue.sourceID,
                                 label: config.wrappedValue.label)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .accessibilityLabel("Remove list")
                Text("Takeout import")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            syncStatusLine(for: config.wrappedValue.sourceID)
        }
    }

    // MARK: - Add a shared Google Maps list

    private var addListSection: some View {
        Section {
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
            .disabled(newListURL.trimmingCharacters(in: .whitespaces).isEmpty || !settings.canAddList)
        } header: {
            Text("Add a Google Maps shared list")
        } footer: {
            if settings.canAddList {
                Text("In Google Maps: your list → Share → send it to FeedYu, or copy the link and paste it here. Starred places can't be shared — import them via Takeout below. If Google changes their page format, sync fails here but the app keeps your last data.")
            } else {
                Text("You've reached \(AppSettings.maxLists) lists — delete one before adding another.")
            }
        }
    }

    private func addSharedList() {
        guard settings.canAddList else { return }
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
            let listLabel: String
            let listKind: ListKind
            if isCSV {
                let listName = url.deletingPathExtension().lastPathComponent
                source = TakeoutImportSource(payload: .listCSV(data, kind: csvImportKind, listName: listName))
                listLabel = listName
                listKind = csvImportKind
            } else {
                source = TakeoutImportSource(payload: .savedPlacesJSON(data))
                listLabel = String(localized: "Starred")
                listKind = .starred
            }
            let isNewList = !settings.importedLists.contains { $0.sourceID == source.id }
            guard !isNewList || settings.canAddList else {
                importMessage = String(localized: "You've reached \(AppSettings.maxLists) lists — delete one before adding another.")
                return
            }
            importMessage = String(localized: "Importing \(url.lastPathComponent)…")
            Task {
                await store.sync(source)
                if let status = store.syncStatuses[source.id] {
                    if let error = status.lastError {
                        importMessage = String(localized: "Import failed: \(error)")
                    } else {
                        settings.registerImportedList(sourceID: source.id, label: listLabel, kind: listKind)
                        importMessage = String(localized: "Imported \(status.lastCount ?? 0) places from \(url.lastPathComponent).")
                    }
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
