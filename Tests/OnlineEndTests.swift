import XCTest
import AVFoundation
@testable import UTubeMusic

final class PlaybackProgressTests: XCTestCase {
    func testDoesNotSkipTheFinalSecondOrCompleteFromUnknownTiming() {
        var monitor = PlaybackProgress()
        XCTAssertEqual(monitor.observe(position: 391, endpoint: 392, now: 0, wantsPlayback: true, recoveries: 0), .none)
        XCTAssertEqual(monitor.observe(position: 391, endpoint: 392, now: 3, wantsPlayback: true, recoveries: 0), .none)
        XCTAssertEqual(monitor.observe(position: 391, endpoint: 392, now: 13, wantsPlayback: true, recoveries: 0), .recover)
        monitor.reset()
        _ = monitor.observe(position: 391, endpoint: nil, now: 0, wantsPlayback: true, recoveries: 0)
        XCTAssertEqual(monitor.observe(position: 391, endpoint: nil, now: 3, wantsPlayback: true, recoveries: 0), .none)
    }
    func testVerifiedEndRecoversWithoutDependingOnPeriodicPlaybackCallbacks() {
        var monitor = PlaybackProgress()
        _ = monitor.observe(position: 391.027, endpoint: 391.05, now: 0, wantsPlayback: true, recoveries: 0)
        XCTAssertEqual(monitor.observe(position: 391.027, endpoint: 391.05, now: 2.1, wantsPlayback: true, recoveries: 0), .finish)
    }
    func testPauseProgressAndSeekResetStallAndRetriesAreBounded() {
        var monitor = PlaybackProgress()
        _ = monitor.observe(position: 20, endpoint: 300, now: 0, wantsPlayback: true, recoveries: 0)
        XCTAssertEqual(monitor.observe(position: 20, endpoint: 300, now: 50, wantsPlayback: false, recoveries: 0), .none)
        XCTAssertEqual(monitor.observe(position: 20, endpoint: 300, now: 51, wantsPlayback: true, recoveries: 0), .none)
        XCTAssertEqual(monitor.observe(position: 21, endpoint: 300, now: 60, wantsPlayback: true, recoveries: 0), .none)
        XCTAssertEqual(monitor.observe(position: 21, endpoint: 300, now: 73, wantsPlayback: true, recoveries: 1), .failed)
        monitor.reset()
        XCTAssertEqual(monitor.observe(position: 100, endpoint: 300, now: 100, wantsPlayback: true, recoveries: 1), .none)
    }
    func testIndependentTimingRejectsInvalidNumbersAndRepairsContainerMismatch() {
        XCTAssertNil(OnlineTiming.endpoint(stream: .nan, media: .infinity))
        XCTAssertEqual(OnlineTiming.endpoint(stream: nil, media: 391.052), 391.052)
        XCTAssertEqual(OnlineTiming.endpoint(stream: 391.05, media: 391.07), 391.07)
        XCTAssertEqual(OnlineTiming.endpoint(stream: 3.04, media: 5.97), 3.04)
        XCTAssertEqual(OnlineTiming.endpoint(stream: 391, media: 391.8), 391.8)
    }
}

@MainActor
final class OnlineEndTests: XCTestCase {
    private func setup(_ kind: String = "regular", count: Int = 2, saved: Bool = true, alternateID: String? = nil) async throws -> (LibraryStore, PlayerStore, [Song], URL, Double, () -> [AVPlayerItem]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let values = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: source))
        let fixture = root.appendingPathComponent("test.m4a")
        try XCTUnwrap(values[kind].flatMap { Data(base64Encoded: $0) }).write(to: fixture)
        let realDuration = try await AudioTiming.read(fixture).duration
        let songs = (1...count).map { Song(id: String(format: "%011d", $0), title: "Track \($0)", artist: "Test", duration: 4) }
        if saved { for song in songs { try library.addOnline(song, favorite: true, playlistIDs: []) } }
        var items: [AVPlayerItem] = []
        var payload: [String: Any] = ["ok": true, "url": "https://r1.googlevideo.com/test", "audio_duration": realDuration]
        if let alternateID { payload["audio_source_id"] = alternateID; payload["loudness_db"] = 3 }
        let response = try JSONDecoder().decode(EngineResponse.self, from: JSONSerialization.data(withJSONObject: payload))
        let player = PlayerStore(library: library, introProbe: { _,_ in nil }, request: { request in
            XCTAssertEqual(request["allow_official_audio"], "1")
            return response
        }, streamItem: { _,_ in
            let item = AVPlayerItem(url: fixture); items.append(item); return item
        })
        return (library,player,songs,fixture,realDuration,{ items })
    }
    private func wait(_ condition: () -> Bool, seconds: Double = 6) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Playback did not reach expected state")
    }
    func testNaturalOnlineEndUsesAudioDurationAndAdvancesWithoutSyntheticNotification() async throws {
        let (library, player, songs, fixture, actual, items) = try await setup()
        let bytes = try Data(contentsOf: fixture)
        defer { player.pause() }
        player.start(songs, at: songs[0])
        try await wait { player.playing && player.duration < 3.2 && items().last?.status == .readyToPlay }
        XCTAssertEqual(player.duration, actual, accuracy: 0.15)
        XCTAssertFalse(try XCTUnwrap(items().last).forwardPlaybackEndTime.isValid)
        player.seek(actual-0.25)
        try await wait { player.current?.id == songs[1].id }
        XCTAssertEqual(library.favorites.count, 2); XCTAssertTrue(library.songs.allSatisfy { $0.fileName == nil })
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }
    func testSearchStreamsUnsavedTracksThroughTheirRealEndWithoutSaving() async throws {
        let (library, player, songs, _, actual, items) = try await setup(saved: false)
        defer { player.pause() }
        player.start(songs, at: songs[0], source: .search)
        try await wait { player.playing && items().last?.status == .readyToPlay }
        XCTAssertEqual(player.playbackSource, .search)
        XCTAssertEqual(player.queuedSong(songs[1].id)?.title, songs[1].title)
        XCTAssertTrue(library.songs.isEmpty)
        player.seek(actual - 0.25)
        try await wait { player.current?.id == songs[1].id && player.playing }
        XCTAssertTrue(library.songs.isEmpty)
        library.toggleFavorite(songs[1])
        XCTAssertEqual(library.favorites.map(\.id), [songs[1].id])
        XCTAssertNil(library.song(songs[1].id)?.fileName)
    }

    func testPublicCollectionPlaysFromChosenTrackAndShufflesWholeListWithoutSaving() async throws {
        let (library, player, songs, file, actual, items) = try await setup(count: 3, saved: false)
        defer { player.pause() }
        var downloaded = songs[0]
        downloaded.fileName = file.lastPathComponent
        downloaded.duration = actual
        downloaded.audioTimingVersion = 1
        try library.save(downloaded, playlistIDs: [])
        let index = library.root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: index)
        let source = PlaybackSource.collection("秋の曲")

        player.start(songs, at: songs[0], source: source)
        XCTAssertEqual(player.current?.fileName, downloaded.fileName)
        XCTAssertTrue(items().isEmpty, "Use the downloaded file without resolving an online stream")
        XCTAssertEqual(player.queue.upcoming, [songs[1].id, songs[2].id])

        player.start(songs, at: songs[1], source: source)
        try await wait { player.playing && items().last?.status == .readyToPlay }
        XCTAssertEqual(player.playbackSource, source)
        XCTAssertEqual(player.queue.upcoming, [songs[2].id])
        player.seek(actual - 0.25)
        try await wait { player.current?.id == songs[2].id && player.playing }

        player.start(songs, at: songs[1], shuffle: true, source: source)
        XCTAssertTrue(player.queue.shuffled)
        XCTAssertEqual(player.queue.current, songs[1].id)
        XCTAssertEqual(Set(player.queue.upcoming), Set([songs[0].id, songs[2].id]))
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testOfficialAudioKeepsOriginalLibraryAndQueueIdentity() async throws {
        let alternate = "official123"
        let (library, player, songs, _, actual, _) = try await setup(count: 1, alternateID: alternate)
        defer { player.pause() }
        let playlist = try library.createPlaylist("夜の曲")
        try library.add(songs[0].id, to: playlist)
        let database = library.root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: database)
        player.start(songs, at: songs[0])
        try await wait { player.playing && player.lyricsSongID == alternate && abs(player.duration - actual) < 0.1 }
        XCTAssertEqual(player.alternateAudioID, alternate)
        XCTAssertEqual(player.current?.id, songs[0].id)
        XCTAssertEqual(player.queue.current, songs[0].id)
        XCTAssertEqual(library.favorites.map(\.id), [songs[0].id])
        XCTAssertEqual(library.playlists.first?.songIDs, [songs[0].id])
        XCTAssertNil(library.song(alternate))
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testDASHMismatchReachesRealEndAndRepeatOneReloadsSameSong() async throws {
        let (_, player, songs, _, actual, items) = try await setup("dash_nonzero_headers")
        defer { player.pause() }
        player.toggleRepeat(); player.toggleRepeat()
        player.start(songs, at: songs[0])
        try await wait { player.playing && player.duration < 3.2 && items().last?.status == .readyToPlay }
        player.seek(actual-0.25)
        try await wait({ items().count >= 2 }, seconds: 8)
        XCTAssertEqual(player.current?.id, songs[0].id); XCTAssertEqual(player.queue.repeatMode, .one)
    }
    func testLastSongStopsInsteadOfKeepingPauseIconAtRoundedEnd() async throws {
        let (_, player, songs, _, actual, items) = try await setup(count: 1)
        defer { player.pause() }
        player.start(songs, at: songs[0])
        try await wait { player.playing && items().last?.status == .readyToPlay }
        player.seek(actual-0.25)
        try await wait { !player.playing }
        XCTAssertEqual(player.current?.id, songs[0].id)
        XCTAssertLessThan(player.duration, 3.2)
        XCTAssertGreaterThan(player.elapsed, 2.7)
    }
    func testPauseNearEndDoesNotAdvanceQueueFromLateCompletionNotification() async throws {
        let (_, player, songs, _, actual, items) = try await setup()
        defer { player.pause() }
        player.start(songs, at: songs[0]); try await wait { player.playing && items().last?.status == .readyToPlay }
        player.seek(actual-0.25); player.pause()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(items().last))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(player.current?.id, songs[0].id); XCTAssertFalse(player.playing)
    }
}
