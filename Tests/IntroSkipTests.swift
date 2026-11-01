import XCTest
import AVFoundation
@testable import UTubeMusic

@MainActor
final class IntroSkipTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, Song, Song, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let data = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source))
        let url = root.appendingPathComponent("regular.m4a")
        try XCTUnwrap(data["regular"].flatMap { Data(base64Encoded: $0) }).write(to: url)
        let list = try library.createPlaylist("Keep")
        let a = Song(id: "00000000001", title: "A", artist: "Test", duration: 3, fileName: "regular.m4a", favorite: true, audioTimingVersion: 1)
        let b = Song(id: "00000000002", title: "B", artist: "Test", duration: 3, fileName: "regular.m4a", audioTimingVersion: 1)
        try library.save(a, playlistIDs: [list]); try library.save(b, playlistIDs: [list])
        return (library, a, b, url)
    }
    private func settle(_ player: PlayerStore) async throws {
        for _ in 0..<300 {
            if player.playing && !player.preparingStartPosition { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Playback did not settle: \(player.error ?? "no error")")
    }
    func testSavedOffsetSurvivesRegistrationChangesAndLeavesAudioAndListsIntact() throws {
        let (library, a, _, url) = try fixture()
        let bytes = try Data(contentsOf: url), playlists = library.playlists
        try library.setIntroSkip(a.id, seconds: 1.25)
        try library.save(a, playlistIDs: []) // metadata refresh / redownload
        let reload = LibraryStore(root: library.root)
        XCTAssertEqual(reload.song(a.id)?.introSkipSeconds, 1.25)
        XCTAssertEqual(reload.playlists, playlists); XCTAssertEqual(reload.song(a.id)?.favorite, true)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try reload.removeDownload(a.id)
        XCTAssertEqual(reload.song(a.id)?.introSkipSeconds, 1.25)
        try reload.setIntroSkip(a.id, seconds: 0)
        XCTAssertEqual(reload.song(a.id)?.startOffset(), 0)
    }
    func testInvalidOffsetsAreRejectedAndOldSongsDefaultToZero() throws {
        let (library, a, _, _) = try fixture()
        XCTAssertEqual(a.startOffset(), 0)
        for value in [-1.0, .nan, .infinity, 31, 2.9] { XCTAssertThrowsError(try library.setIntroSkip(a.id, seconds: value)) }
        XCTAssertNil(library.song(a.id)?.introSkipSeconds)
        var damaged = a; damaged.introSkipSeconds = 100
        XCTAssertEqual(damaged.startOffset(duration: 2), 1.5)
        damaged.introSkipSeconds = .nan; XCTAssertEqual(damaged.startOffset(), 0)
    }
    func testLocalStartRepeatAndPreviousUseOffsetAndManualSeekStillWorks() async throws {
        let (library, a, _, _) = try fixture()
        try library.setIntroSkip(a.id, seconds: 0.5)
        let player = PlayerStore(library: library); player.normalizeVolume = false
        defer { player.pause(); UserDefaults.standard.removeObject(forKey: "normalizeVolume") }
        player.start([a], at: a); try await settle(player)
        XCTAssertGreaterThanOrEqual(player.elapsed, 0.49)
        player.seek(0); XCTAssertEqual(player.elapsed, 0)
        player.previous(); try await settle(player); XCTAssertGreaterThanOrEqual(player.elapsed, 0.49)
        player.toggleRepeat(); player.toggleRepeat()
        player.next(automatically: true); try await settle(player)
        XCTAssertEqual(player.current?.id, a.id); XCTAssertGreaterThanOrEqual(player.elapsed, 0.49)
    }
    func testOnlineStartAdvanceAndRepeatApplyEachSongsOffset() async throws {
        let (library, a, b, url) = try fixture()
        try library.removeDownload(a.id); try library.removeDownload(b.id)
        // Recreate the same synthetic fixture for the injected online player only.
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let data = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source))
        try XCTUnwrap(data["regular"].flatMap { Data(base64Encoded: $0) }).write(to: url)
        try library.setIntroSkip(a.id, seconds: 0.5); try library.setIntroSkip(b.id, seconds: 1)
        let response = try JSONDecoder().decode(EngineResponse.self, from: Data(#"{"ok":true,"url":"https://r1.googlevideo.com/audio"}"#.utf8))
        let player = PlayerStore(library: library, request: { _ in response }, streamItem: { _, _ in AVPlayerItem(url: url) })
        defer { player.pause() }
        player.start([a,b], at: a); try await settle(player)
        XCTAssertGreaterThanOrEqual(player.elapsed, 0.49)
        player.next(automatically: true)
        for _ in 0..<300 { if player.current?.id == b.id && player.playing && !player.preparingStartPosition { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(player.current?.id, b.id); XCTAssertGreaterThanOrEqual(player.elapsed, 0.99)
        player.toggleRepeat(); player.toggleRepeat(); player.next(automatically: true)
        try await Task.sleep(nanoseconds: 100_000_000); try await settle(player)
        XCTAssertEqual(player.current?.id, b.id); XCTAssertGreaterThanOrEqual(player.elapsed, 0.99)
        XCTAssertNil(library.song(a.id)?.fileName); XCTAssertNil(library.song(b.id)?.fileName)
    }
}
