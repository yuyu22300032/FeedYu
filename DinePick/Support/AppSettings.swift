import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private static let budgetKey = "driveBudgetMinutes"
    private static let sharedListsKey = "sharedListConfigs"
    private static let languageChoiceKey = "languageChoice"
    private static let michelinNameLanguageKey = "michelinNameLanguage"

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
    }

    var sharedListSources: [GoogleSharedListSource] {
        sharedLists.map { GoogleSharedListSource(config: $0) }
    }
}
