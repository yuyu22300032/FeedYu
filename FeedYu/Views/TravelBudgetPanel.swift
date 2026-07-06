import SwiftUI

/// Boxed travel-constraint selector shared by the Tonight and Michelin tabs:
/// mode buttons (distance / walk / drive) on top, a preset slider below.
/// Finer-grained values live in Settings; the slider snaps to presets.
struct TravelBudgetPanel: View {
    @EnvironmentObject private var settings: AppSettings
    /// false when embedded in a grouped List row — the row is the box there
    /// (the panel's own gray fill would vanish against the list background).
    var boxed = true
    /// Uber Eats tab: straight-line distance is all that matters for
    /// delivery — no mode row, slider drives distanceBudgetMeters directly
    /// (the other tabs' mode choice is untouched).
    var distanceOnly = false

    private var activeMode: TravelMode { distanceOnly ? .distance : settings.travelMode }

    private var activeBudget: TravelBudget {
        distanceOnly ? TravelBudget(mode: .distance, value: settings.distanceBudgetMeters)
                     : settings.travelBudget
    }

    var body: some View {
        VStack(spacing: 14) {
            if !distanceOnly {
                HStack(spacing: 8) {
                    ForEach(TravelMode.allCases) { mode in
                        let isOn = settings.travelMode == mode
                        Button {
                            settings.travelMode = mode
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.systemImage)
                                    .font(.body.weight(.medium))
                                Text(mode.label)
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isOn ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 12) {
                if distanceOnly {
                    Image(systemName: TravelMode.distance.systemImage)
                        .foregroundStyle(.secondary)
                }
                Slider(value: budgetSliderIndex,
                       in: 0...Double(TravelBudget.presets(for: activeMode).count - 1),
                       step: 1)
                    .id(activeMode) // rebuild when the preset scale changes
                Text(activeBudget.label)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 88, alignment: .trailing)
            }
        }
        .padding(boxed ? 12 : 0)
        .background(boxed ? AnyShapeStyle(Color(.secondarySystemBackground)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// Slider position ↔ nearest preset of the active mode.
    private var budgetSliderIndex: Binding<Double> {
        Binding {
            let presets = TravelBudget.presets(for: activeMode)
            let value = activeBudget.value
            let nearest = presets.enumerated().min {
                abs($0.element - value) < abs($1.element - value)
            }
            return Double(nearest?.offset ?? 0)
        } set: { position in
            let presets = TravelBudget.presets(for: activeMode)
            let index = min(max(Int(position.rounded()), 0), presets.count - 1)
            if distanceOnly {
                settings.distanceBudgetMeters = presets[index]
            } else {
                settings.setTravelBudgetValue(presets[index])
            }
        }
    }
}
