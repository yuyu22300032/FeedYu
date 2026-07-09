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
                // One size for all three buttons. Width: flexible equal
                // thirds (minWidth 0 + scale-to-fit text, so long
                // translations or large Dynamic Type can't widen one).
                // Height: the SF Symbols differ in natural height (the
                // walking figure is tall, the ruler squat), so each icon
                // gets a fixed-height slot — otherwise each background
                // wrapped its own icon and Walk stood taller than the rest.
                HStack(spacing: 8) {
                    ForEach(TravelMode.allCases) { mode in
                        let isOn = settings.travelMode == mode
                        Button {
                            settings.travelMode = mode
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.systemImage)
                                    .font(.body.weight(.medium))
                                    .frame(height: 24)
                                Text(mode.label)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isOn ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 10) {
                if distanceOnly {
                    Image(systemName: TravelMode.distance.systemImage)
                        .foregroundStyle(.secondary)
                }
                // Slider = coarse presets; +/− = fine steps in between.
                stepButton(direction: -1, systemImage: "minus.circle.fill")
                Slider(value: budgetSliderIndex,
                       in: 0...Double(TravelBudget.presets(for: activeMode).count - 1),
                       step: 1)
                    .id(activeMode) // rebuild when the preset scale changes
                stepButton(direction: 1, systemImage: "plus.circle.fill")
                Text(activeBudget.label)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 76, alignment: .trailing)
            }
        }
        .padding(boxed ? 12 : 0)
        // White box on the gray page (grouped-style row color); unboxed
        // inside a List, where the row itself is the box.
        .background(boxed ? AnyShapeStyle(Color(.secondarySystemGroupedBackground)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func stepButton(direction: Int, systemImage: String) -> some View {
        Button {
            // One preset slot, exactly like nudging the slider (its setter
            // clamps to the scale's ends).
            budgetSliderIndex.wrappedValue += Double(direction)
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(direction > 0 ? "Increase budget" : "Decrease budget")
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
