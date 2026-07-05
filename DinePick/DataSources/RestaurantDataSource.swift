import Foundation

/// Abstraction over every way restaurants enter the app. When Google changes
/// their page format only the affected source breaks — the local store and the
/// rest of the app keep working.
protocol RestaurantDataSource {
    /// Stable identifier used for sync-status bookkeeping and lastSeen stamps.
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> [Restaurant]
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
