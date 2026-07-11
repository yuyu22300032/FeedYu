import Foundation

/// The app's single local source of truth. Sources sync *into* this store;
/// sync failures never block the app — it keeps serving the last good data.
@MainActor
final class RestaurantStore: ObservableObject {
    @Published private(set) var restaurants: [Restaurant] = [] {
        didSet {
            version &+= 1
            var index: [UUID: Int] = Dictionary(minimumCapacity: restaurants.count)
            for (i, r) in restaurants.enumerated() { index[r.id] = i }
            indexByID = index
        }
    }
    @Published private(set) var syncStatuses: [String: SyncStatus] = [:]
    @Published private(set) var syncingSourceIDs: Set<String> = []
    @Published private(set) var isLoaded = false

    /// Bumped on every restaurants mutation — views key their memoized
    /// derived collections on it instead of comparing 20k-row arrays.
    private(set) var version = 0
    private var indexByID: [UUID: Int] = [:]

    private var saveTask: Task<Void, Never>?
    /// Hard cap for the current save-coalescing burst (see scheduleSave).
    private var saveDeadline: Date?

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
            Self.loadSnapshot(from: url)
        }.value
        if let snapshot {
            restaurants = snapshot.restaurants
            syncStatuses = snapshot.syncStatuses
        }
    }

    /// Reads and decodes the store file. A file that EXISTS but fails to
    /// decode is set aside as `store.json.corrupt` before returning nil —
    /// the app then starts empty and the next save would otherwise
    /// overwrite the user's only copy. The set-aside file is recoverable
    /// via the container-surgery recipe (see MAINTENANCE.md "All my
    /// restaurants disappeared"); only the newest corrupt copy is kept.
    nonisolated static func loadSnapshot(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            return snapshot
        }
        let corrupt = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try? FileManager.default.moveItem(at: url, to: corrupt)
        return nil
    }

    /// Debounce with a deadline: each mutation restarts a 3 s timer (one
    /// multi-MB store rewrite per burst, not one per mutation — a localizer
    /// fill run lands ~40 names seconds apart), but a burst can't starve the
    /// disk past 20 s, bounding what a force-quit mid-burst could lose.
    private func scheduleSave() {
        saveTask?.cancel()
        let previous = saveTask
        let snapshot = Snapshot(restaurants: restaurants, syncStatuses: syncStatuses)
        let now = Date()
        let deadline = saveDeadline ?? now.addingTimeInterval(20)
        saveDeadline = deadline
        let delay = max(0, min(now.addingTimeInterval(3), deadline).timeIntervalSince(now))
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Serialize BEFORE the cancellation check: a cancelled-in-sleep
            // task must still wait for its predecessor, or its successor's
            // own `await previous` completes instantly and severs the chain
            // back to a write already in flight — two concurrent multi-MB
            // .atomic writes can land out of order, the OLDER snapshot
            // winning the rename. Waiting first keeps the chain transitive;
            // a cancelled waiter does no work of its own afterwards.
            await previous?.value
            guard !Task.isCancelled else { return }
            await MainActor.run { self.saveDeadline = nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: RestaurantStore.storeFileURL, options: .atomic)
            }
        }
    }

    /// O(1) row lookup — views re-read live rows on every render, and a
    /// linear scan over a 20k-row store per render was the cost.
    func restaurant(withID id: UUID) -> Restaurant? {
        indexByID[id].map { restaurants[$0] }
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
            apply(fetched, sourceID: source.id, removesMissing: source.fetchIsCompleteList)
            status.lastSuccess = Date()
            status.lastError = nil
            status.lastCount = fetched.count
        } catch {
            status.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        syncStatuses[source.id] = status
        scheduleSave()
    }

    /// Merge fetched records into the store. Failures never delete anything.
    /// With `removesMissing` (complete-list sources, e.g. shared Google
    /// lists), a *successful* sync also unstamps places the source no longer
    /// returned — removing rows with no other reason to exist — but only
    /// when the fetch looks healthy: a Google format drift that parses half
    /// the page must not mass-delete, so removal is skipped when the fetch
    /// returned less than half the places previously stamped by this source.
    func apply(_ fetched: [Restaurant], sourceID: String, removesMissing: Bool = false) {
        var updated = restaurants
        let now = Date()
        let previouslyStamped = restaurants.filter { $0.lastSeenInSourceAt[sourceID] != nil }.count
        var stampedIDs = Set<UUID>()

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
            // name only when unambiguous — and only into rows the USER put
            // there (any non-guide source stamp, or manually added). With
            // ~19k guide rows loaded, "unique in the whole store" let a
            // coordinate-less row merge into a same-named Michelin place
            // anywhere on earth; the user's place inherited the foreign
            // coordinates and silently fell out of every radius. The
            // discriminator is the source stamps, NOT michelinAward: a user
            // place that merged with its local guide row carries the award,
            // and excluding it appended a coordinate-less duplicate on
            // every re-import. Guide-only rows still merge via the
            // name + ≤150 m rule above.
            let userRows = candidates.filter { index in
                updated[index].addedManually
                    || updated[index].lastSeenInSourceAt.keys.contains { $0 != "michelin" }
            }
            return userRows.count == 1 ? userRows[0] : nil
        }

        for var incoming in fetched {
            incoming.lastSeenInSourceAt[sourceID] = now
            if let index = matchIndex(for: incoming) {
                updated[index].merge(with: incoming)
                stampedIDs.insert(updated[index].id)
            } else {
                let index = updated.count
                updated.append(incoming)
                stampedIDs.insert(incoming.id)
                indexByName[incoming.normalizedName, default: []].append(index)
                if let url = incoming.googleMapsURL { indexByURL[url.absoluteString] = index }
            }
        }

        if removesMissing, !fetched.isEmpty, fetched.count * 2 >= previouslyStamped {
            updated = updated.compactMap { row in
                guard row.lastSeenInSourceAt[sourceID] != nil, !stampedIDs.contains(row.id) else { return row }
                var unstamped = row
                unstamped.lastSeenInSourceAt[sourceID] = nil
                // Same survival rules as removing a whole list.
                let keep = unstamped.addedManually
                    || unstamped.michelinAward != nil
                    || !unstamped.lastSeenInSourceAt.isEmpty
                return keep ? unstamped : nil
            }
        }

        restaurants = updated
        scheduleSave()
    }

    // MARK: - User edits

    /// Removes a user list: strips its source stamp everywhere and deletes
    /// the restaurants that belonged ONLY to it. A place survives when it is
    /// manually added, part of the Michelin dataset, or stamped by any other
    /// still-registered list (enabled or not).
    func removeList(sourceID: String, otherListSourceIDs: Set<String>) {
        restaurants = restaurants.compactMap { restaurant in
            guard restaurant.lastSeenInSourceAt[sourceID] != nil else { return restaurant }
            var updated = restaurant
            updated.lastSeenInSourceAt[sourceID] = nil
            let onAnotherList = updated.lastSeenInSourceAt.keys.contains { otherListSourceIDs.contains($0) }
            let keep = updated.addedManually
                || updated.michelinAward != nil
                || updated.lastSeenInSourceAt["michelin"] != nil
                || onAnotherList
            return keep ? updated : nil
        }
        syncStatuses[sourceID] = nil
        scheduleSave()
    }

    func setHidden(_ hidden: Bool, id: UUID) {
        guard let index = indexByID[id] else { return }
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
        guard let index = indexByID[id] else { return }
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

    /// One-time cleanup: store URLs captured by the v1 name-only matcher
    /// were unreliable; wipe them so the geo-verified checker re-resolves.
    func clearAllUberEatsURLs() {
        for index in restaurants.indices where restaurants[index].uberEatsURL != nil {
            restaurants[index].uberEatsURL = nil
        }
        scheduleSave()
    }

    /// A resolved cid link must never clobber a source-provided *exact*
    /// place URL (sources are authoritative; resolution is best-effort).
    /// Source-provided search URLs (Takeout list CSVs) may be upgraded to
    /// an exact link — that's the point of resolving.
    func setGoogleMapsURL(id: UUID, url: URL) {
        guard let index = indexByID[id] else { return }
        if let existing = restaurants[index].googleMapsURL {
            guard !GoogleMapsOpener.isExactPlaceURL(existing),
                  GoogleMapsOpener.isExactPlaceURL(url) else { return }
        }
        restaurants[index].googleMapsURL = url
        restaurants[index].mapsNoMatchAt = nil
        restaurants[index].mapsNoMatchName = nil
        scheduleSave()
    }

    /// Definitive "cid resolution found nothing near this place" — skipped
    /// for a cooldown period instead of re-spending a 1–2 MB search per
    /// session. Cleared by a later success (setGoogleMapsURL).
    func setMapsNoMatch(id: UUID, searchName: String) {
        guard let index = indexByID[id] else { return }
        restaurants[index].mapsNoMatchAt = Date()
        restaurants[index].mapsNoMatchName = searchName
        scheduleSave()
    }

    /// Verified "not on Uber Eats" — the Uber tab skips this place for a
    /// cooldown period instead of re-running a slow WebView check every
    /// session. Cleared by a later success (setUberEatsURL).
    func setUberEatsNotFound(id: UUID) {
        guard let index = indexByID[id] else { return }
        restaurants[index].uberEatsNotFoundAt = Date()
        scheduleSave()
    }

    func setUberEatsURL(id: UUID, url: URL) {
        guard let index = indexByID[id],
              restaurants[index].uberEatsURL != url else { return }
        restaurants[index].uberEatsURL = url
        restaurants[index].uberEatsNotFoundAt = nil
        scheduleSave()
    }

    func setLocalizedName(id: UUID, editionKey: String, name: String) {
        guard let index = indexByID[id] else { return }
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
