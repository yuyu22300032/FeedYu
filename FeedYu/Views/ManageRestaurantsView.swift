import SwiftUI
import CoreLocation

/// Browse, hide/unhide, delete, and manually add restaurants.
struct ManageRestaurantsView: View {
    @EnvironmentObject private var store: RestaurantStore
    @State private var searchText = ""
    @State private var showingAddSheet = false

    /// Only the user's own places — the 7.5k-row Michelin dataset would drown
    /// the list (hide Michelin places from their own tab instead).
    /// Memoized (gotcha #12): one body evaluation reads these lists several
    /// times (headers, ForEach, isEmpty), and each uncached compute filtered
    /// and locale-sorted the whole ~20k-row store on the main thread — per
    /// render, per search keystroke. One pass fills both, keyed on
    /// store.version + the search text; the box is a plain reference in
    /// @State so it survives re-renders without triggering any.
    private final class PlacesCache {
        var key: String?
        var visible: [Restaurant] = []
        var hidden: [Restaurant] = []
    }
    @State private var placesCache = PlacesCache()

    private var places: PlacesCache {
        let key = "\(store.version)|\(searchText)"
        if placesCache.key == key { return placesCache }
        var visible: [Restaurant] = []
        var hidden: [Restaurant] = [] // ALL hidden places, guide rows too — unhide lives here
        for restaurant in store.restaurants {
            guard searchText.isEmpty
                    || restaurant.name.localizedCaseInsensitiveContains(searchText) else { continue }
            if restaurant.isHidden {
                hidden.append(restaurant)
            } else if !restaurant.lists.isEmpty || restaurant.addedManually {
                visible.append(restaurant)
            }
        }
        let byName: (Restaurant, Restaurant) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        visible.sort(by: byName)
        hidden.sort(by: byName)
        placesCache.visible = visible
        placesCache.hidden = hidden
        placesCache.key = key
        return placesCache
    }

    var body: some View {
        List {
            sections
        }
        .searchable(text: $searchText, prompt: "Search restaurants")
        .navigationTitle("Restaurants")
        .toolbar {
            Button {
                showingAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddRestaurantSheet()
        }
    }

    @ViewBuilder
    private var sections: some View {
        // The header counts exactly the rows below it — hidden places used
        // to be counted here while the rows filtered them out, so the
        // number visibly disagreed with the list whenever anything was
        // hidden (they show under "Hidden" instead).
        Section("Your places (\(places.visible.count))") {
            ForEach(places.visible) { restaurant in
                row(restaurant)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.remove(id: restaurant.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            store.setHidden(true, id: restaurant.id)
                        } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                    }
            }
        }
        if !places.hidden.isEmpty {
            Section("Hidden (\(places.hidden.count))") {
                ForEach(places.hidden) { restaurant in
                    row(restaurant)
                        .swipeActions(edge: .trailing) {
                            Button {
                                store.setHidden(false, id: restaurant.id)
                            } label: {
                                Label("Unhide", systemImage: "eye")
                            }
                        }
                }
            }
        }
    }

    private func row(_ restaurant: Restaurant) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(restaurant.name)
            HStack(spacing: 6) {
                if let award = restaurant.michelinAward {
                    Text(award.badge).font(.caption2)
                }
                ForEach(Array(restaurant.lists).sorted { $0.rawValue < $1.rawValue }) { kind in
                    Text(kind.label).font(.caption2).foregroundStyle(.blue)
                }
                if restaurant.addedManually {
                    Text("Manual").font(.caption2).foregroundStyle(.orange)
                }
                if restaurant.coordinate == nil {
                    Text("No location").font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }
}

struct AddRestaurantSheet: View {
    @EnvironmentObject private var store: RestaurantStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var isGeocoding = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Address (used to find coordinates)", text: $address)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add restaurant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGeocoding {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        isGeocoding = true
        defer { isGeocoding = false }
        var restaurant = Restaurant(name: name.trimmingCharacters(in: .whitespaces))
        restaurant.addedManually = true
        let query = [restaurant.name, address].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let placemark = try? await CLGeocoder().geocodeAddressString(query).first,
           let location = placemark.location {
            restaurant.latitude = location.coordinate.latitude
            restaurant.longitude = location.coordinate.longitude
            restaurant.address = address.isEmpty ? placemark.name : address
        } else if !address.isEmpty {
            restaurant.address = address
            message = String(localized: "Couldn't find coordinates — saved without location (excluded from distance filtering).")
        }
        store.addManual(restaurant)
        dismiss()
    }
}
