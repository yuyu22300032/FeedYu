import SwiftUI
import CoreLocation

/// Browse, hide/unhide, delete, and manually add restaurants.
struct ManageRestaurantsView: View {
    @EnvironmentObject private var store: RestaurantStore
    @State private var searchText = ""
    @State private var showingAddSheet = false

    /// Only the user's own places — the 7.5k-row Michelin dataset would drown
    /// the list (hide Michelin places from their own tab instead).
    private var userPlaces: [Restaurant] {
        store.restaurants
            .filter { !$0.lists.isEmpty || $0.addedManually }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hiddenPlaces: [Restaurant] {
        store.restaurants
            .filter(\.isHidden)
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section("Your places (\(userPlaces.count))") {
                ForEach(userPlaces.filter { !$0.isHidden }) { restaurant in
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
            if !hiddenPlaces.isEmpty {
                Section("Hidden (\(hiddenPlaces.count))") {
                    ForEach(hiddenPlaces) { restaurant in
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
