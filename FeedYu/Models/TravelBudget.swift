import Foundation

/// How "close enough for tonight" is measured.
enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case distance   // straight-line — exact, needs no route lookups
    case walking    // route-verified walk time
    case driving    // route-verified drive time in current traffic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .distance: return String(localized: "Distance")
        case .walking: return String(localized: "Walk")
        case .driving: return String(localized: "Drive")
        }
    }

    var systemImage: String {
        switch self {
        case .distance: return "ruler"
        case .walking: return "figure.walk"
        case .driving: return "car.fill"
        }
    }
}

/// A travel constraint: meters for .distance, minutes for .walking/.driving.
/// Distance is the cheap rough filter (no route calls at all); walk/drive
/// verify the route time only for the place actually being suggested.
struct TravelBudget: Equatable, Hashable {
    var mode: TravelMode
    var value: Int

    /// Straight-line prefilter radius. Exact for distance mode; generous
    /// (assumes a direct route) for walk/drive — the per-candidate route
    /// check is what enforces the real budget.
    var radiusMeters: Double {
        switch mode {
        case .distance: return Double(value)
        case .walking: return Double(value) * 85     // ~5 km/h straight line
        case .driving: return Double(value) * 1300   // 1.3 km per minute
        }
    }

    /// Distance mode is exact by construction — no route verification.
    var needsETACheck: Bool { mode != .distance }

    var maxTravelSeconds: TimeInterval { Double(value) * 60 }

    /// "500 m" / "2 km" / "15 min walk" / "60 min drive"
    var label: String {
        switch mode {
        case .distance: return Self.formatMeters(value)
        case .walking: return String(localized: "\(value) min walk")
        case .driving: return String(localized: "\(value) min drive")
        }
    }

    static func formatMeters(_ meters: Int) -> String {
        Measurement(value: Double(meters), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// Quick-selector choices on the Tonight page.
    static func presets(for mode: TravelMode) -> [Int] {
        switch mode {
        case .distance: return [200, 500, 1000, 2000, 5000, 10000, 20000, 50000]
        case .walking: return [5, 10, 15, 20, 30, 45, 60]
        case .driving: return [15, 30, 45, 60, 90]
        }
    }

    static let distanceRange = 100...50_000
}
