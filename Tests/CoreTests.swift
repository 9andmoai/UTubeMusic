import XCTest

@testable import UTubeMusic

final class EmbeddedRuntimeTests: XCTestCase {
    func testEmbeddedPythonAndWebKitProviderImportWithoutNetwork() async throws {
        let response = try await PythonService.shared.request(["op": "selftest"])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.songs?.count, 0)
    }
}

final class QueueTests: XCTestCase {
    func testSequentialStopsAtEndAndManualNextOverridesRepeatOne() {
        var q = PlaybackQueue(); q.start(["a", "b", "c"], at: "a")
        q.repeatMode = .one
        XCTAssertEqual(q.advance(automatically: true), "a")
        XCTAssertEqual(q.advance(automatically: false), "b")
        q.repeatMode = .off
        XCTAssertEqual(q.advance(automatically: true), "c")
        XCTAssertNil(q.advance(automatically: true))
    }
    func testRepeatAllWrapsAndPreviousRetracesShuffle() {
        var q = PlaybackQueue(); q.start(["a", "b", "c", "d"], at: "c", shuffle: true)
        XCTAssertEqual(q.current, "c")
        XCTAssertEqual(Set(q.order), Set(["a", "b", "c", "d"]))
        let second = q.advance(automatically: false)
        XCTAssertEqual(q.previous(), "c")
        XCTAssertEqual(q.advance(automatically: false), second)
        q.repeatMode = .all
        _ = q.advance(automatically: true); _ = q.advance(automatically: true)
        let last = q.current
        XCTAssertNotEqual(q.advance(automatically: true), last)
    }
    func testShuffleOffPreservesCurrentAndRemovalPreservesPosition() {
        var q = PlaybackQueue(); q.start(["a", "b", "b", "c"], at: "b")
        q.toggleShuffle(); q.toggleShuffle()
        XCTAssertEqual(q.current, "b"); XCTAssertEqual(q.order, ["a", "b", "c"])
        q.remove("a"); XCTAssertEqual(q.current, "b")
        q.remove("b"); XCTAssertEqual(q.current, "c")
        q.remove("c"); XCTAssertNil(q.current)
    }
    func testEmptyAndSingleSongQueues() {
        var q = PlaybackQueue(); XCTAssertNil(q.advance(automatically: false))
        q.start(["a"], at: "a", shuffle: true); q.repeatMode = .all
        XCTAssertEqual(q.advance(automatically: true), "a")
        q.append("a"); XCTAssertEqual(q.order, ["a"])
    }
    func testRangeValidation() {
        XCTAssertEqual(AudioTransfer.parseRange("bytes 0-99/100")?.total, 100)
        XCTAssertEqual(AudioTransfer.parseRange("bytes 100-199/200")?.start, 100)
        XCTAssertNil(AudioTransfer.parseRange("bytes */100"))
        XCTAssertNil(AudioTransfer.parseRange("bytes 9-2/100"))
        XCTAssertNil(AudioTransfer.parseRange("bytes -1-2/100"))
        XCTAssertNil(AudioTransfer.parseRange("bytes +1-2/100"))
        XCTAssertNil(AudioTransfer.parseRange("bytes 0-100/100"))
        XCTAssertNil(AudioTransfer.parseRange("garbage"))
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testDeleteRemovesFileAndPlaylistReferencesAndAllowsResave() async throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let file = root.appendingPathComponent("song.m4a")
        try Data([1, 2, 3]).write(to: file)
        let song = Song(id: "song", title: "Title", artist: "Artist", duration: 100, fileName: "song.m4a")
        let playlist = try store.createPlaylist("My music")
        try store.save(song, playlistID: playlist)
        try store.add(song.id, to: playlist)
        XCTAssertEqual(store.playlists[0].songIDs.count, 1)
        try store.delete(song)
        XCTAssertTrue(store.songs.isEmpty); XCTAssertTrue(store.playlists[0].songIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data([4]).write(to: file)
        try store.save(song, playlistID: playlist)
        XCTAssertEqual(store.songs.count, 1)
        let reloaded = LibraryStore(root: root)
        XCTAssertEqual(reloaded.songs[0].id, song.id)
        XCTAssertEqual(reloaded.playlists[0].songIDs, [song.id])
    }
    func testCorruptIndexIsNeverOverwritten() async throws {
        let root = try makeRoot(), url = root.appendingPathComponent("library.json")
        let original = Data("not JSON".utf8); try original.write(to: url)
        let store = LibraryStore(root: root)
        XCTAssertTrue(store.recoveryNeeded)
        XCTAssertThrowsError(try store.createPlaylist("New"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testWriteFailureRollsBackStateAndKeepsAudio() async throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let song = Song(id: "a", title: "A", artist: "B", duration: 10, fileName: "a.m4a")
        try Data([1]).write(to: root.appendingPathComponent("a.m4a"))
        try store.save(song, playlistID: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.previous.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.delete(song))
        XCTAssertEqual(store.songs.count, 1); XCTAssertTrue(store.isAvailable(song))
    }
    func testPlaylistReorderAndDeleteKeepSongs() async throws {
        let store = LibraryStore(root: try makeRoot())
        let id = try store.createPlaylist("Mix")
        for key in ["a", "b", "c", "d"] { try store.save(Song(id: key, title: key, artist: "Artist", duration: 1), playlistID: id) }
        try store.move(in: id, from: IndexSet([0, 2]), to: 4)
        XCTAssertEqual(store.playlists[0].songIDs, ["b", "d", "a", "c"])
        try store.deletePlaylist(id)
        XCTAssertEqual(store.songs.count, 4); XCTAssertTrue(store.playlists.isEmpty)
    }
    func testUntrustedFileNamesStayInsideLibrary() async throws {
        let store = LibraryStore(root: try makeRoot())
        for path in ["../escape", "/tmp/escape", "..", "a\\b", ""] { XCTAssertNil(store.file(path)) }
        XCTAssertEqual(store.file("safe.m4a")?.deletingLastPathComponent().standardizedFileURL.path, store.root.standardizedFileURL.path)
    }
    func testMultiPlaylistSaveAndAlbumOrderSurvivePartialCompletionAndReload() async throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let album = try store.createPlaylist("Album"), other = try store.createPlaylist("Other")
        try store.setSourceOrder(["a", "b", "c"], sourceID: "MPREb_album", for: album)
        for key in ["c", "a", "b"] {
            try store.save(Song(id: key, title: key, artist: "Artist", duration: 1, favorite: true), playlistIDs: [album, other])
        }
        let reloaded = LibraryStore(root: root)
        XCTAssertEqual(reloaded.playlists.first(where: { $0.id == album })?.songIDs, ["a", "b", "c"])
        XCTAssertEqual(reloaded.playlists.first(where: { $0.id == other })?.songIDs, ["c", "a", "b"])
        XCTAssertEqual(reloaded.favorites.count, 3)
        XCTAssertEqual(reloaded.playlists.first(where: { $0.id == album })?.sourceID, "MPREb_album")
        try reloaded.move(in: album, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(reloaded.playlists.first(where: { $0.id == album })?.songIDs, ["b", "c", "a"])
    }
    func testLegacySnapshotWithoutImportFieldsStillLoads() async throws {
        let root = try makeRoot(), id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "songs": [], "playlists": [["id": id.uuidString, "name": "Old", "songIDs": [], "createdAt": 1]]])
        try data.write(to: root.appendingPathComponent("library.json"))
        let store = LibraryStore(root: root)
        XCTAssertFalse(store.recoveryNeeded); XCTAssertEqual(store.playlists.first?.name, "Old")
        XCTAssertNil(store.playlists.first?.sourceID)
    }
    func testAddingSavedSongsFromCollectionsPreservesFilesAndOtherMemberships() async throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let first = try store.createPlaylist("First"), second = try store.createPlaylist("Second")
        let file = root.appendingPathComponent("saved.m4a")
        let original = Data([1, 2, 3]); try original.write(to: file)
        let song = Song(id: "saved", title: "Saved", artist: "Artist", duration: 1, fileName: file.lastPathComponent)
        try store.save(song, playlistID: first)
        try SongAddDestination.favorites.add(song, to: store)
        try SongAddDestination.playlist(second).add(song, to: store)
        try SongAddDestination.playlist(second).add(song, to: store)
        let reloaded = LibraryStore(root: root)
        XCTAssertEqual(reloaded.songs.count, 1); XCTAssertTrue(reloaded.song(song.id)?.favorite == true)
        for id in [first, second] { XCTAssertEqual(reloaded.playlists.first(where: { $0.id == id })?.songIDs, [song.id]) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testDeletedAddDestinationAndMissingAudioFailWithoutChangingLibrary() async throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let file = root.appendingPathComponent("saved.m4a")
        try Data([1]).write(to: file)
        let song = Song(id: "saved", title: "Saved", artist: "Artist", duration: 1, fileName: file.lastPathComponent)
        try store.save(song, playlistID: nil)
        let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try SongAddDestination.playlist(UUID()).add(song, to: store))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try SongAddDestination.favorites.add(song, to: store))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
    }
}

@MainActor
final class FollowPersistenceTests: XCTestCase {
    func testFollowAndRemoteCoverSurviveReloadAndUnfollowKeepsPlaylist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let playlist = try library.createPlaylist("Album")
        let cover = "https://example.com/cover.jpg"
        try library.setSourceOrder([], sourceID: "MPREb_album", for: playlist, cover: cover)
        let source = FollowSource(id: "MPSPPL12345", kind: "podcast", title: "News", subtitle: "", thumbnail: nil)
        try library.toggleFollow(source)
        let reloaded = LibraryStore(root: root)
        XCTAssertEqual(reloaded.follows, [source])
        reloaded.updatePodcastCover(cover, id: source.id)
        XCTAssertEqual(LibraryStore(root: root).follows.first?.thumbnail, cover)
        XCTAssertEqual(LibraryStore(root: root).follows.first?.id, source.id)
        XCTAssertEqual(reloaded.playlists.first?.cover, cover)
        try reloaded.toggleFollow(source)
        let after = LibraryStore(root: root)
        XCTAssertTrue(after.follows.isEmpty)
        XCTAssertEqual(after.playlists.first?.id, playlist)
    }
}

@MainActor
final class CollectionDownloadTests: XCTestCase {
    func testBulkDownloadSelectsOnlyMissingRegisteredAudioAndDeduplicatesJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let music = MusicService(library: library)
        let playlist = try library.createPlaylist("Playlist")
        let online = Song(id: "00000000001", title: "Online", artist: "Artist", duration: 30)
        let saved = Song(id: "00000000002", title: "Offline", artist: "Artist", duration: 30, fileName: "saved.m4a")
        try Data([1]).write(to: root.appendingPathComponent("saved.m4a"))
        try library.addOnline(online, favorite: true, playlistIDs: [playlist])
        try library.save(saved, playlistIDs: [playlist])
        let songs = [saved, online, online]
        XCTAssertEqual(music.pendingDownloads(in: songs).map(\.id), [online.id])
        music.downloadSavedSongs(songs)
        music.downloadSavedSongs(songs)
        defer { music.cancelPending() }
        XCTAssertEqual(music.jobs.map { $0.song.id }, [online.id])
        XCTAssertTrue(music.jobs[0].requiresRegistration)
        XCTAssertTrue(music.jobs[0].playlistIDs.isEmpty)
        XCTAssertEqual(library.playlists.first?.songIDs, [online.id, saved.id])
        XCTAssertEqual(library.favorites.map(\.id), [online.id])
    }
}
