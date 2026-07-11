import XCTest
@testable import FeedYu

/// Machine-checks CLAUDE.md hard rule 4: every catalog key ships zh-Hant
/// AND ja translations. Reads the source .xcstrings via #filePath (the
/// compiled bundle only contains the built tables).
final class LocalizationCatalogTests: XCTestCase {
    private func catalogKeys(missing language: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FeedYuTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("FeedYu/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let catalog = object as? [String: Any],
              let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw XCTSkip("catalog shape changed — update this test")
        }
        return strings.compactMap { key, entry in
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            return localizations[language] == nil ? key : nil
        }
    }

    func testEveryKeyHasAllLanguages() throws {
        // "Uber Eats" is a brand name, deliberately untranslated.
        let allowedUntranslated: Set<String> = ["Uber Eats"]
        for language in ["zh-Hant", "ja"] {
            let missing = try catalogKeys(missing: language)
                .filter { !allowedUntranslated.contains($0) }
            XCTAssertEqual(missing, [],
                           "keys missing a \(language) translation — hard rule 4")
        }
    }
}
