import Foundation
import Testing
@testable import CastorEngine

@Suite struct HistoryStoreTests {
    private func makeStore() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("castor-history-\(UUID().uuidString)", isDirectory: true)
        return (HistoryStore(directory: dir), dir)
    }

    @Test func upsertsAndOrdersByRecency() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        await store.update(path: "/a.mkv", title: "A", position: 100, duration: 5000, deviceName: "TV")
        await store.update(path: "/b.mkv", title: "B", position: 50, duration: 5000, deviceName: nil)
        await store.update(path: "/a.mkv", title: "A", position: 200, duration: 5000, deviceName: "TV")

        let entries = await store.all()
        #expect(entries.count == 2)
        #expect(entries[0].path == "/a.mkv")
        #expect(entries[0].position == 200)
        #expect(entries[1].path == "/b.mkv")
    }

    @Test func persistsAcrossInstances() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        await store.update(path: "/movie.mkv", title: "Movie", position: 1234, duration: 4907, deviceName: "Salon")

        let reloaded = HistoryStore(directory: dir)
        let entry = await reloaded.entry(forPath: "/movie.mkv")
        #expect(entry?.position == 1234)
        #expect(entry?.deviceName == "Salon")
    }

    @Test func capsEntryCount() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<60 {
            await store.update(path: "/file-\(i).mkv", title: "F\(i)", position: 60, duration: 100, deviceName: nil)
        }
        let entries = await store.all()
        #expect(entries.count == HistoryStore.maxEntries)
        #expect(entries.first?.path == "/file-59.mkv")
    }

    @Test func resumabilityThresholds() {
        func entry(position: Double, duration: Double) -> HistoryEntry {
            HistoryEntry(path: "/x", title: "x", position: position, duration: duration, deviceName: nil, updatedAt: Date())
        }
        #expect(!entry(position: 10, duration: 5000).isResumable)   // barely started
        #expect(entry(position: 1000, duration: 5000).isResumable)  // mid-film
        #expect(!entry(position: 4900, duration: 5000).isResumable) // credits
    }
}
