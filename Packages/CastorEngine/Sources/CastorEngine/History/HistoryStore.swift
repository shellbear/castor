import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var position: Double
    public var duration: Double
    public var deviceName: String?
    public var updatedAt: Date

    public var fractionWatched: Double {
        duration > 0 ? min(position / duration, 1) : 0
    }

    /// Worth offering a resume (not just started, not effectively finished).
    public var isResumable: Bool {
        position > 30 && fractionWatched < 0.95
    }
}

/// Playback history persisted as JSON in Application Support. Small, simple,
/// and diffable — a database earns its place once there's a library feature.
public actor HistoryStore {
    public static let maxEntries = 50

    private let fileURL: URL
    private var entries: [HistoryEntry] = []
    private var loaded = false

    /// - Parameter directory: override for tests; defaults to
    ///   `~/Library/Application Support/Castor`.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Castor", isDirectory: true)
        self.fileURL = base.appendingPathComponent("history.json")
    }

    public func all() -> [HistoryEntry] {
        loadIfNeeded()
        return entries
    }

    public func entry(forPath path: String) -> HistoryEntry? {
        loadIfNeeded()
        return entries.first { $0.path == path }
    }

    /// Upserts by path and moves the entry to the front (most recent first).
    public func update(
        path: String,
        title: String,
        position: Double,
        duration: Double,
        deviceName: String?
    ) {
        loadIfNeeded()
        entries.removeAll { $0.path == path }
        entries.insert(
            HistoryEntry(
                path: path,
                title: title,
                position: position,
                duration: duration,
                deviceName: deviceName,
                updatedAt: Date()
            ),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    public func remove(path: String) {
        loadIfNeeded()
        entries.removeAll { $0.path == path }
        save()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // History is best-effort; never break playback over it.
        }
    }
}
