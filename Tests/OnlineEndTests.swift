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
    }
}

@MainActor
final class OnlineEndTests: XCTestCase {
    private func setup(_ kind: String = "regular", count: Int = 2) async throws -> (LibraryStore, PlayerStore, [Song], URL, Double, () -> [AVPlayerItem]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let values = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: source))
        let fixture = root.appendingPathComponent("test.m4a")
        try XCTUnwrap(values[kind].flatMap { Data(base64Encoded: $0) }).write(to: fixture)
        let realDuration = try await AudioTiming.read(fixture).duration
        let songs = (1...count).map { Song(id: String(format: "%011d", $0), title: "Track \($0)", artist: "Test", duration: 4) }
        for song in songs { try library.addOnline(song, favorite: true, playlistIDs: []) }
        var items: [AVPlayerItem] = []
        let response: EngineResponse = try JSONDecoder().decode(EngineResponse.self, from: JSONSerialization.data(withJSONObject: [
            "ok": true, "url": "https://r1.googlevideo.com/test", "audio_duration": realDuration]))
        let player = PlayerStore(library: library, introProbe: { _,_ in nil }, request: { _ in response }, streamItem: { _,_ in
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
