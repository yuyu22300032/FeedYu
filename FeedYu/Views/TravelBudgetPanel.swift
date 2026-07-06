import SwiftUI

/// Boxed travel-constraint selector shared by the Tonight and Michelin tabs:
/// mode buttons (distance / walk / drive) on top, a preset slider below.
/// Finer-grained values live in Settings; the slider snaps to presets.
struct TravelBudgetPanel: View {
    @EnvironmentObject private var settings: AppSettings
    /// false when embedded in a grouped List row — the row is the box there
    /// (the panel's own gray fill would vanish against the list background).
    var boxed = true

    var body: some View {
        VStack(spacing: 14) {
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
            HStack(spacing: 12) {
                Slider(value: budgetSliderIndex,
                       in: 0...Double(TravelBudget.presets(for: settings.travelMode).count - 1),
                       step: 1)
                    .id(settings.travelMode) // rebuild when the preset scale changes
                Text(settings.travelBudget.label)
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

    /// Slider position ↔ nearest preset of the current mode.
    private var budgetSliderIndex: Binding<Double> {
        Binding {
            let presets = TravelBudget.presets(for: settings.travelMode)
            let value = settings.travelBudget.value
            let nearest = presets.enumerated().min {
                abs($0.element - value) < abs($1.element - value)
            }
            return Double(nearest?.offset ?? 0)
        } set: { position in
            let presets = TravelBudget.presets(for: settings.travelMode)
            let index = min(max(Int(position.rounded()), 0), presets.count - 1)
            settings.setTravelBudgetValue(presets[index])
        }
    }
}
