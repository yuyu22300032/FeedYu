import Foundation

/// A Takeout import that has been registered as a toggleable list. Identified
/// by the import source's stable sourceID ("takeout-starred",
/// "takeout-csv-<normalized name>").
struct ImportedListConfig: Codable, Identifiable, Hashable {
    var sourceID: String
    var label: String
    var kind: ListKind = .custom
    var isEnabled = true

    var id: String { sourceID }

    init(sourceID: String, label: String, kind: ListKind = .custom, isEnabled: Bool = true) {
        self.sourceID = sourceID
        self.label = label
        self.kind = kind
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        kind = try container.decodeIfPresent(ListKind.self, forKey: .kind) ?? .custom
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private static let budgetKey = "driveBudgetMinutes"
    private static let sharedListsKey = "sharedListConfigs"
    private static let importedListsKey = "importedListConfigs"
    private static let languageChoiceKey = "languageChoice"
    private static let michelinNameLanguageKey = "michelinNameLanguage"

    /// Hard cap on user lists (shared links + Takeout imports combined).
    static let maxLists = 20

    /// "system", or a language code ("en", "zh-Hant", "ja"). Applied via the
    /// AppleLanguages override, which takes effect on next launch.
    @Published var languageChoice: String {
        didSet {
            UserDefaults.standard.set(languageChoice, forKey: Self.languageChoiceKey)
            if languageChoice == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([languageChoice], forKey: "AppleLanguages")
            }
        }
    }

    /// "local" | "en" | "zh" | "ja" — which guide edition to show Michelin
    /// restaurant names in. Local = the restaurant's own country's edition.
    @Published var michelinNameLanguage: String {
        didSet { UserDefaults.standard.set(michelinNameLanguage, forKey: Self.michelinNameLanguageKey) }
    }

    /// The choice that was active when this process started; differing from
    /// languageChoice means a restart is needed.
    let languageChoiceAtLaunch: String

    var languageRestartNeeded: Bool { languageChoice != languageChoiceAtLaunch }

    @Published var driveBudgetMinutes: Int {
        didSet { UserDefaults.standard.set(driveBudgetMinutes, forKey: Self.budgetKey) }
    }

    @Published var sharedLists: [SharedListConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(sharedLists) {
                UserDefaults.standard.set(data, forKey: Self.sharedListsKey)
            }
        }
    }

    @Published var importedLists: [ImportedListConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(importedLists) {
                UserDefaults.standard.set(data, forKey: Self.importedListsKey)
            }
        }
    }

    init() {
        let storedChoice = UserDefaults.standard.string(forKey: Self.languageChoiceKey) ?? "system"
        languageChoice = storedChoice
        languageChoiceAtLaunch = storedChoice
        michelinNameLanguage = UserDefaults.standard.string(forKey: Self.michelinNameLanguageKey) ?? "local"
        let storedBudget = UserDefaults.standard.integer(forKey: Self.budgetKey)
        driveBudgetMinutes = (15...90).contains(storedBudget) ? storedBudget : 60
        if let data = UserDefaults.standard.data(forKey: Self.sharedListsKey),
           let configs = try? JSONDecoder().decode([SharedListConfig].self, from: data) {
            sharedLists = configs
        } else {
            sharedLists = []
        }
        if let data = UserDefaults.standard.data(forKey: Self.importedListsKey),
           let configs = try? JSONDecoder().decode([ImportedListConfig].self, from: data) {
            importedLists = configs
        } else {
            importedLists = []
        }
    }

    var sharedListSources: [GoogleSharedListSource] {
        sharedLists.map { GoogleSharedListSource(config: $0) }
    }

    // MARK: - List registry

    var listCount: Int { sharedLists.count + importedLists.count }
    var canAddList: Bool { listCount < Self.maxLists }

    /// Source IDs whose places should feed the Tonight suggestions.
    var enabledListSourceIDs: Set<String> {
        var ids = Set(sharedLists.filter(\.isEnabled).map(\.sourceID))
        ids.formUnion(importedLists.filter(\.isEnabled).map(\.sourceID))
        return ids
    }

    /// Display label for a list source ID, if it belongs to a known list.
    func listLabel(forSourceID sourceID: String) -> String? {
        if let shared = sharedLists.first(where: { $0.sourceID == sourceID }) {
            return shared.label.isEmpty ? String(localized: "Shared list") : shared.label
        }
        return importedLists.first(where: { $0.sourceID == sourceID })?.label
    }

    /// Upsert a Takeout import as a toggleable list. Keeps the user's
    /// existing toggle state on re-import.
    func registerImportedList(sourceID: String, label: String, kind: ListKind) {
        if let index = importedLists.firstIndex(where: { $0.sourceID == sourceID }) {
            importedLists[index].label = label
            importedLists[index].kind = kind
        } else {
            importedLists.append(ImportedListConfig(sourceID: sourceID, label: label, kind: kind))
        }
    }

    /// Registers lists for Takeout imports done before the list registry
    /// existed, so their places keep feeding Tonight suggestions.
    func registerLegacyImports(from restaurants: [Restaurant]) {
        var seen = Set(importedLists.map(\.sourceID))
        for restaurant in restaurants {
            for sourceID in restaurant.lastSeenInSourceAt.keys where !seen.contains(sourceID) {
                if sourceID == "takeout-starred" {
                    registerImportedList(sourceID: sourceID, label: String(localized: "Starred"), kind: .starred)
                    seen.insert(sourceID)
                } else if sourceID.hasPrefix("takeout-csv-") {
                    let label = String(sourceID.dropFirst("takeout-csv-".count))
                    registerImportedList(sourceID: sourceID, label: label, kind: .custom)
                    seen.insert(sourceID)
                }
            }
        }
    }
}
