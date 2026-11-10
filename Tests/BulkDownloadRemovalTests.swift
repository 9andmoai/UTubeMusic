import XCTest
@testable import UTubeMusic

@MainActor
final class BulkDownloadRemovalTests: XCTestCase {
    private func makeStore(failSecond: Bool = false) throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root, removeDownloadedFile: { url in
            if failSecond && url.lastPathComponent == "1.m4a" { throw AppFailure("Denied") }
            try FileManager.default.removeItem(at: url)
        })
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let list = try store.createPlaylist("Keep all tracks")
        for index in 0..<3 {
            let name = "\(index).m4a"
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
            let song = Song(id: String(format: "%011d", index + 1), title: "Track \(index)", artist: "Artist",
                            duration: 5, fileName: name, bytes: 3, favorite: true)
            try store.save(song, playlistIDs: [list])
        }
        return store
    }
    func testBulkDeletionDeduplicatesAndPreservesAllRegistrationsAndOrder() async throws {
        let store = try makeStore(), original = store.playlists
        let ids = store.songs.map(\.id)
        var callbacks: [String] = [], processed: [Int] = []
        let report = await store.removeDownloads([ids[0], ids[1], ids[0]], didRemove: { callbacks.append($0) }, progress: { processed.append($0); XCTAssertEqual($1, 2) })
        XCTAssertEqual(report.removed, [ids[0], ids[1]]); XCTAssertEqual(callbacks, report.removed)
        XCTAssertEqual(processed, [1, 2]); XCTAssertTrue(report.failures.isEmpty)
        let reload = LibraryStore(root: store.root)
        XCTAssertEqual(reload.playlists, original); XCTAssertEqual(reload.songs.count, 3); XCTAssertEqual(reload.favorites.count, 3)
        XCTAssertEqual(reload.songs.filter(reload.isAvailable).count, 1); XCTAssertEqual(reload.totalBytes, 3)
        XCTAssertEqual(reload.songs.filter { $0.onlineOnly == true }.count, 2)
    }
    func testOneFailedDeletionDoesNotDiscardOtherResultsOrMemberships() async throws {
        let store = try makeStore(failSecond: true), original = store.playlists
        let report = await store.removeDownloads(store.songs.map(\.id))
        XCTAssertEqual(report.removed.count, 2); XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(store.playlists, original); XCTAssertEqual(store.favorites.count, 3)
        let failed = try XCTUnwrap(store.song("00000000002"))
        XCTAssertTrue(store.isAvailable(failed)); XCTAssertEqual(failed.fileName, "1.m4a")
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("1.m4a")), Data([1, 2, 3]))
    }
    func testCancellationKeepsUnprocessedAudioAndEveryPlaylistReference() async throws {
        let store = try makeStore(), original = store.playlists
        var task: Task<DownloadRemovalReport, Never>?
        task = Task { await store.removeDownloads(store.songs.map(\.id), progress: { done, _ in if done == 1 { task?.cancel() } }) }
        let report = await task!.value
        XCTAssertTrue(report.cancelled); XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(store.playlists, original); XCTAssertEqual(store.songs.count, 3)
        XCTAssertEqual(store.songs.filter(store.isAvailable).count, 2)
        XCTAssertEqual(store.favorites.count, 3)
    }
}
