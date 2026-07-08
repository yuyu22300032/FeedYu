import Foundation

/// Abstraction over every way restaurants enter the app. When Google changes
/// their page format only the affected source breaks — the local store and the
/// rest of the app keep working.
protocol RestaurantDataSource {
    /// Stable identifier used for sync-status bookkeeping and lastSeen stamps.
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> [Restaurant]
    /// True when fetch() returns the source's COMPLETE current membership —
    /// a successful sync may then unstamp places it no longer returned
    /// (removing rows with no other reason to exist). The store still
    /// guards against suspiciously small parses; see `RestaurantStore.apply`.
    var fetchIsCompleteList: Bool { get }
}

extension RestaurantDataSource {
    var fetchIsCompleteList: Bool { false }
}

struct SyncStatus: Codable, Hashable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastError: String?
    var lastCount: Int?
}

enum SourceError: LocalizedError {
    case badURL(String)
    case httpStatus(Int)
    case parseFailed(String)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return String(localized: "Not a valid URL: \(s)")
        case .httpStatus(let code): return String(localized: "Server returned HTTP \(code).")
        case .parseFailed(let why): return why
        case .unreadableFile(let why): return why
        }
    }
}
