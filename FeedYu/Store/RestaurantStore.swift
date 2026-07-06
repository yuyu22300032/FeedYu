import Foundation

/// The app's single local source of truth. Sources sync *into* this store;
/// sync failures never block the app — it keeps serving the last good data.
@MainActor
final class RestaurantStore: ObservableObject {
    @Published private(set) var restaurants: [Restaurant] = []
    @Published private(set) var syncStatuses: [String: SyncStatus] = [:]
    @Published private(set) var syncingSourceIDs: Set<String> = []
    @Published private(set) var isLoaded = false

    private var saveTask: Task<Void, Never>?

    struct Snapshot: Codable {
        var restaurants: [Restaurant]
        var syncStatuses: [String: SyncStatus]
    }

    nonisolated static var storeFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FeedYu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    // MARK: - Persistence

    func load() async {
        defer { isLoaded = true }
        let url = Self.storeFileURL
        let snapshot: Snapshot? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Snapshot.self, from: data)
        }.value
        if let snapshot {
            restaurants = snapshot.restaurants
            syncStatuses = snapshot.syncStatuses
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(restaurants: restaurants, syncStatuses: syncStatuses)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: RestaurantStore.storeFileURL, options: .atomic)
            }
        }
    }

    // MARK: - Sync

    func sync(_ source: any RestaurantDataSource) async {
        guard !syncingSourceIDs.contains(source.id) else { return }
        syncingSourceIDs.insert(source.id)
        defer { syncingSourceIDs.remove(source.id) }

        var status = syncStatuses[source.id] ?? SyncStatus()
        status.lastAttempt = Date()
        do {
            let fetched = try await source.fetch()
            apply(fetched, sourceID: source.id)
            status.lastSuccess = Date()
            status.lastError = nil
            status.lastCount = fetched.count
        } catch {
            status.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        syncStatuses[source.id] = status
        scheduleSave()
    }

    /// Merge fetched records into the store. Never deletes: places a source
    /// stopped returning just keep an older lastSeenInSourceAt stamp.
    func apply(_ fetched: [Restaurant], sourceID: String) {
        var updated = restaurants
        let now = Date()

        // Hash indexes so a 7.5k-row Michelin sync stays O(n).
        var indexByName: [String: [Int]] = [:]
        var indexByURL: [String: Int] = [:]
        for (index, r) in updated.enumerated() {
            indexByName[r.normalizedName, default: []].append(index)
            if let url = r.googleMapsURL { indexByURL[url.absoluteString] = index }
        }

        func matchIndex(for incoming: Restaurant) -> Int? {
            if let url = incoming.googleMapsURL, let index = indexByURL[url.absoluteString] {
                return index
            }
            guard let candidates = indexByName[incoming.normalizedName], !candidates.isEmpty else { return nil }
            if let incomingLocation = incoming.location {
                // Same normalized name AND within ~150 m → same place.
                for index in candidates {
                    if let existing = updated[index].location,
                       existing.distance(from: incomingLocation) <= 150 {
                        return index
                    }
                }
                return nil
            }
            // Incoming has no coordinates (e.g. Takeout list CSV): match by
            // name only when unambiguous.
            return candidates.count == 1 ? candidates[0] : nil
        }

        for var incoming in fetched {
            incoming.lastSeenInSourceAt[sourceID] = now
            if let index = matchIndex(for: incoming) {
                updated[index].merge(with: incoming)
            } else {
                let index = updated.count
                updated.append(incoming)
                indexByName[incoming.normalizedName, default: []].append(index)
                if let url = incoming.googleMapsURL { indexByURL[url.absoluteString] = index }
            }
        }
        restaurants = updated
        scheduleSave()
    }

    // MARK: - User edits

    func setHidden(_ hidden: Bool, id: UUID) {
        guard let index = restaurants.firstIndex(where: { $0.id == id }) else { return }
        restaurants[index].isHidden = hidden
        scheduleSave()
    }

    func remove(id: UUID) {
        restaurants.removeAll { $0.id == id }
        scheduleSave()
    }

    func addManual(_ restaurant: Restaurant) {
        var r = restaurant
        r.addedManually = true
        apply([r], sourceID: "manual")
    }

    /// Fill-only (never overwrites existing data) — scraped info must not
    /// clobber anything a source or the user already provided.
    func setPlaceInfo(id: UUID, summary: String?, imageURL: URL?) {
        guard let index = restaurants.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if restaurants[index].summary == nil, let summary {
            restaurants[index].summary = summary
            changed = true
        }
        if restaurants[index].imageURL == nil, let imageURL {
            restaurants[index].imageURL = imageURL
            changed = true
        }
        if changed { scheduleSave() }
    }

    func setLocalizedName(id: UUID, editionKey: String, name: String) {
        guard let index = restaurants.firstIndex(where: { $0.id == id }) else { return }
        var names = restaurants[index].localizedNames ?? [:]
        names[editionKey] = name
        restaurants[index].localizedNames = names
        scheduleSave()
    }

    func clearSyncStatus(sourceID: String) {
        syncStatuses[sourceID] = nil
        scheduleSave()
    }
}
