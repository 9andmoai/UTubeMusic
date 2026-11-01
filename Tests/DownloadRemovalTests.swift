import XCTest
@testable import UTubeMusic

@MainActor
final class DownloadRemovalTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func saved(_ store: LibraryStore, id: String = "00000000001") throws -> Song {
        let bytes = Data([1, 2, 3])
        try bytes.write(to: store.root.appendingPathComponent("audio.m4a"))
        try Data([4, 5]).write(to: store.root.appendingPathComponent("cover.jpg"))
        let song = Song(id: id, title: "Title", artist: "Artist", duration: 3,
                        fileName: "audio.m4a", artworkName: "cover.jpg", bytes: 3,
                        favorite: true, audioTimingVersion: 1)
        try store.save(song, playlistIDs: [])
        return song
    }
    func testRemovalKeepsMetadataArtworkAllMembershipsAndAllowsRedownload() async throws {
        let root = try folder(), store = LibraryStore(root: root)
        let original = try saved(store)
        let first = try store.createPlaylist("One"), second = try store.createPlaylist("Two")
        try store.add(original.id, to: first); try store.add(original.id, to: second)
        try store.removeDownload(original.id)
        let reloaded = LibraryStore(root: root), online = try XCTUnwrap(reloaded.song(original.id))
        XCTAssertNil(online.fileName); XCTAssertEqual(online.bytes, 0); XCTAssertTrue(online.onlineOnly == true)
        XCTAssertEqual(online.title, original.title); XCTAssertEqual(online.artist, original.artist)
        XCTAssertEqual(online.addedAt, original.addedAt); XCTAssertEqual(online.duration, original.duration)
        XCTAssertTrue(online.favorite); XCTAssertEqual(online.artworkName, original.artworkName)
        XCTAssertTrue(reloaded.isPlayable(online)); XCTAssertFalse(reloaded.isAvailable(online))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.m4a").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("cover.jpg")), Data([4, 5]))
        for list in reloaded.playlists { XCTAssertEqual(list.songIDs, [original.id]) }
        try Data([6, 7]).write(to: root.appendingPathComponent("again.m4a"))
        var downloaded = online; downloaded.fileName = "again.m4a"; downloaded.bytes = 2; downloaded.onlineOnly = nil
        try reloaded.save(downloaded, playlistIDs: [])
        XCTAssertTrue(reloaded.isAvailable(try XCTUnwrap(reloaded.song(original.id))))
        XCTAssertEqual(reloaded.songs.count, 1); XCTAssertEqual(reloaded.playlists.count, 2)
    }
    func testFailedIndexWriteNeverDeletesAudio() async throws {
        let root = try folder(), store = LibraryStore(root: root)
        let song = try saved(store)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.previous.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.removeDownload(song.id))
        XCTAssertEqual(store.song(song.id), song)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("audio.m4a")), Data([1, 2, 3]))
    }
    func testFailedFileDeletionRestoresDownloadedRegistration() async throws {
        let root = try folder(), store = LibraryStore(root: root, removeDownloadedFile: { _ in throw AppFailure("Denied") })
        let song = try saved(store)
        XCTAssertThrowsError(try store.removeDownload(song.id))
        XCTAssertEqual(store.song(song.id), song)
        XCTAssertEqual(LibraryStore(root: root).song(song.id), song)
        XCTAssertTrue(store.isAvailable(song))
    }
    func testImportedAudioCannotBeConvertedToUnavailableOnlineSource() async throws {
        let store = LibraryStore(root: try folder())
        let song = try saved(store, id: "local-import")
        XCTAssertFalse(store.canRemoveDownload(song))
        XCTAssertThrowsError(try store.removeDownload(song.id))
        XCTAssertTrue(store.isAvailable(song)); XCTAssertEqual(store.song(song.id), song)
    }
    func testSharedAudioIsRetainedForAnotherSong() async throws {
        let store = LibraryStore(root: try folder())
        let song = try saved(store)
        var other = Song(id: "00000000002", title: "Other", artist: "Artist", duration: 3)
        other.fileName = song.fileName
        try store.save(other, playlistIDs: [])
        try store.removeDownload(song.id)
        XCTAssertTrue(store.isAvailable(other)); XCTAssertNil(store.song(song.id)?.fileName)
        XCTAssertTrue(store.song(song.id)?.onlineOnly == true)
    }
    func testReleasingCurrentDownloadKeepsQueueAndRepeatMode() async throws {
        let store = LibraryStore(root: try folder())
        let song = try saved(store)
        let player = PlayerStore(library: store, introProbe: { _, _ in nil }, request: { _ in throw AppFailure("No network in test") })
        player.start([song], at: song)
        player.toggleShuffle(); player.toggleRepeat()
        let order = player.queue.order, mode = player.queue.repeatMode
        try store.removeDownload(song.id)
        player.releaseRemovedDownload(song.id)
        XCTAssertFalse(player.playing); XCTAssertEqual(player.current?.id, song.id)
        XCTAssertTrue(player.current?.onlineOnly == true)
        XCTAssertEqual(player.queue.order, order); XCTAssertEqual(player.queue.repeatMode, mode)
        XCTAssertTrue(player.queue.shuffled); XCTAssertEqual(player.elapsed, 0)
    }
}
