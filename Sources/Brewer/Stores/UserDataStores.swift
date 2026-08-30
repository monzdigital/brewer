import Foundation
import Observation

// MARK: - MetaStore (favorites, tags, notes, collections, snoozes)

@MainActor
@Observable
final class MetaStore {

    private struct Payload: Codable {
        var favorites: Set<String> = []
        var packageTags: [String: Set<String>] = [:]
        var notes: [String: String] = [:]
        var collections: [PackageCollection] = []
        var snoozes: [String: SnoozeInfo] = [:]
    }

    var favorites: Set<String> = []
    var packageTags: [String: Set<String>] = [:]
    var notes: [String: String] = [:]
    var collections: [PackageCollection] = []
    var snoozes: [String: SnoozeInfo] = [:]

    private var saveTask: Task<Void, Never>?

    static let storageDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Brewer", isDirectory: true)
    }()

    private var fileURL: URL { Self.storageDirectory.appendingPathComponent("metadata.json") }

    init() {
        load()
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        scheduleSave()
    }

    // MARK: Tags

    var allTags: [String] {
        Set(packageTags.values.flatMap { $0 }).sorted()
    }

    func tags(for id: String) -> [String] {
        (packageTags[id] ?? []).sorted()
    }

    func packageIDs(withTag tag: String) -> Set<String> {
        Set(packageTags.filter { $0.value.contains(tag) }.keys)
    }

    func addTag(_ tag: String, to id: String) {
        let cleaned = tag.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }
        packageTags[id, default: []].insert(cleaned)
        scheduleSave()
    }

    func removeTag(_ tag: String, from id: String) {
        packageTags[id]?.remove(tag)
        if packageTags[id]?.isEmpty == true { packageTags[id] = nil }
        scheduleSave()
    }

    // MARK: Notes

    func note(for id: String) -> String { notes[id] ?? "" }

    func setNote(_ text: String, for id: String) {
        if text.isEmpty { notes[id] = nil } else { notes[id] = text }
        scheduleSave()
    }

    // MARK: Collections

    @discardableResult
    func addCollection(named name: String) -> PackageCollection {
        let collection = PackageCollection(name: name)
        collections.append(collection)
        scheduleSave()
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = name
        scheduleSave()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        scheduleSave()
    }

    func collection(id: UUID) -> PackageCollection? {
        collections.first { $0.id == id }
    }

    func toggleMembership(packageID: String, collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if let existing = collections[index].packageIDs.firstIndex(of: packageID) {
            collections[index].packageIDs.remove(at: existing)
        } else {
            collections[index].packageIDs.append(packageID)
        }
        scheduleSave()
    }

    // MARK: Snoozes

    func snooze(_ id: String, until: Date?, version: String?) {
        snoozes[id] = SnoozeInfo(until: until, version: version)
        scheduleSave()
    }

    func unsnooze(_ id: String) {
        snoozes[id] = nil
        scheduleSave()
    }

    /// A snooze is active while its date hasn't passed and/or the snoozed version is still the latest.
    func isSnoozed(_ id: String, latestVersion: String?) -> Bool {
        guard let info = snoozes[id] else { return false }
        if let until = info.until, until > Date() { return true }
        if let version = info.version, let latest = latestVersion, version == latest { return true }
        if info.until == nil && info.version == nil { return true }
        return false
    }

    var snoozedIDs: Set<String> { Set(snoozes.keys) }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        favorites = payload.favorites
        packageTags = payload.packageTags
        notes = payload.notes
        collections = payload.collections
        snoozes = payload.snoozes
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        let payload = Payload(
            favorites: favorites,
            packageTags: packageTags,
            notes: notes,
            collections: collections,
            snoozes: snoozes
        )
        do {
            try FileManager.default.createDirectory(at: Self.storageDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persisting metadata is best-effort.
        }
    }
}

// MARK: - HistoryStore

@MainActor
@Observable
final class HistoryStore {

    var entries: [HistoryEntry] = []

    private var fileURL: URL { MetaStore.storageDirectory.appendingPathComponent("history.json") }

    init() {
        load()
    }

    func record(_ operation: TaskConsole.Operation) {
        let entry = HistoryEntry(
            date: operation.startedAt ?? operation.enqueuedAt,
            title: operation.title,
            command: operation.commandLine,
            succeeded: operation.state == .succeeded,
            durationSeconds: operation.duration
        )
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: MetaStore.storageDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence.
        }
    }
}
