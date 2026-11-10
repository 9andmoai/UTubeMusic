import XCTest
import AVFoundation
@testable import UTubeMusic

final class AudioTimingTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ name: String, in folder: URL) throws -> URL {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(values[name].flatMap { Data(base64Encoded: $0) })
        let source = folder.appendingPathComponent(name + ".m4a")
        try data.write(to: source)
        return source
    }
    private func assertToneAndSilence(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        XCTAssertEqual(Double(file.length) / rate, 3, accuracy: 0.15)
        func rms(at seconds: Double) throws -> Float {
            file.framePosition = AVAudioFramePosition(seconds * rate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            XCTAssertGreaterThan(buffer.frameLength, 0)
            let sum = (0..<Int(buffer.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
            return sqrt(sum / Float(max(1, buffer.frameLength)))
        }
        XCTAssertLessThan(try rms(at: 0.8), 0.005)
        XCTAssertGreaterThan(try rms(at: 2.7), 0.05)
    }
    func testRegularM4AUsesFrameLengthAndPreservesIntentionalSilence() async throws {
        let folder = try root(), source = try fixture("regular", in: folder)
        let original = try Data(contentsOf: source)
        let timing = try await AudioTiming.read(source)
        XCTAssertEqual(timing.duration, 3, accuracy: 0.15)
        try assertToneAndSilence(source)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testDASHDoubledContainerDurationDoesNotChangeActualAudioLength() async throws {
        let folder = try root(), source = try fixture("dash_nonzero_headers", in: folder)
        let original = try Data(contentsOf: source)
        let timing = try await AudioTiming.read(source)
        print("DASH regression: raw container duration", timing.containerDuration, "actual audio", timing.duration)
        XCTAssertGreaterThan(timing.containerDuration, 5.5)
        XCTAssertEqual(timing.duration, 3, accuracy: 0.15)
        try assertToneAndSilence(source)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testInvalidAudioAndCancellationDoNotAlterFiles() async throws {
        let folder = try root(), invalid = folder.appendingPathComponent("invalid.m4a")
        let bytes = Data("invalid audio".utf8); try bytes.write(to: invalid)
        do { _ = try await AudioTiming.read(invalid); XCTFail("Invalid media must fail") }
        catch { XCTAssertEqual(try Data(contentsOf: invalid), bytes) }
        let valid = try fixture("regular", in: folder), original = try Data(contentsOf: valid)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AudioTiming.read(valid)
        }
        do { _ = try await work.value; XCTFail("Cancelled work must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: valid), original)
    }
    @MainActor
    func testRepairPreservesAudioFavoritesPlaylistsOrderAndAddedDate() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder), bytes = try Data(contentsOf: source)
        let first = try store.createPlaylist("First"), second = try store.createPlaylist("Second")
        let song = Song(id: "AbCdEf123_-", title: "Saved", artist: "Artist", duration: 6,
                        fileName: source.lastPathComponent, favorite: true)
        try store.save(song, playlistIDs: [first, second])
        XCTAssertNil(LibraryStore(root: folder).song(song.id)?.audioTimingVersion)
        let service = MusicService(library: store)
        await service.repairSavedSongs()
        let updated = try XCTUnwrap(store.song(song.id))
        XCTAssertEqual(updated.duration, 3, accuracy: 0.15)
        XCTAssertEqual(updated.audioTimingVersion, 1)
        XCTAssertTrue(updated.favorite); XCTAssertEqual(updated.addedAt, song.addedAt)
        XCTAssertEqual(updated.fileName, song.fileName)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        for id in [first, second] { XCTAssertEqual(store.playlists.first(where: { $0.id == id })?.songIDs, [song.id]) }
        let reload = LibraryStore(root: folder)
        XCTAssertEqual(reload.song(song.id), updated); XCTAssertTrue(reload.isAvailable(updated))
        await service.repairSavedSongs()
        XCTAssertEqual(store.song(song.id), updated)
    }
    @MainActor
    func testRepairDASHOnlyUpdatesIndexAndRetainsOriginalAudio() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("dash_nonzero_headers", in: folder), original = try Data(contentsOf: source)
        let song = Song(id: "AbCdEf123_-", title: "DASH", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        try store.save(song, playlistIDs: [])
        await MusicService(library: store).repairSavedSongs()
        let updated = try XCTUnwrap(store.song(song.id))
        XCTAssertEqual(updated.duration, 3, accuracy: 0.15)
        XCTAssertEqual(updated.audioTimingVersion, 1)
        XCTAssertEqual(updated.fileName, song.fileName)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertToneAndSilence(source)
    }
    @MainActor
    func testIndexWriteFailurePreservesOriginalIndexAndAudio() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder), original = try Data(contentsOf: source)
        let song = Song(id: "AbCdEf123_-", title: "Saved", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        try store.save(song, playlistIDs: [])
        let index = try Data(contentsOf: folder.appendingPathComponent("library.json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("library.previous.json"), withIntermediateDirectories: false)
        await MusicService(library: store).repairSavedSongs()
        XCTAssertEqual(store.song(song.id), song)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("library.json")), index)
    }
    @MainActor
    func testPlaybackCorrectsDoubledIndexWithoutRewritingAudio() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder), original = try Data(contentsOf: source)
        let song = Song(id: "AbCdEf123_-", title: "Saved", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        try store.save(song, playlistIDs: [])
        let player = PlayerStore(library: store, introProbe: { _, _ in nil }); player.start([song], at: song); player.pause()
        let deadline = Date().addingTimeInterval(5)
        while player.duration > 3.15 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(player.duration, 3, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(player.current).duration, 3, accuracy: 0.15)
        player.seek(6); XCTAssertLessThan(player.elapsed, 3.15)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    @MainActor
    func testDASHPlaybackAdvancesAtRealEndAndRepeatOneStillWorks() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("dash_nonzero_headers", in: folder), original = try Data(contentsOf: source)
        let first = Song(id: "first", title: "First", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        let second = Song(id: "second", title: "Second", artist: "Artist", duration: 3,
                          fileName: source.lastPathComponent, audioTimingVersion: 1)
        try store.save(first, playlistIDs: []); try store.save(second, playlistIDs: [])
        let player = PlayerStore(library: store, introProbe: { _, _ in nil }); player.start([first, second], at: first)
        let deadline = Date().addingTimeInterval(5)
        while player.duration > 3.15 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(player.duration, 3, accuracy: 0.15)
        player.seek(2.7)
        let nextDeadline = Date().addingTimeInterval(2)
        while player.current?.id == first.id && Date() < nextDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        player.pause(); XCTAssertEqual(player.current?.id, second.id)
        player.toggleRepeat(); player.toggleRepeat()
        XCTAssertEqual(player.queue.repeatMode, .one)
        player.seek(2.7); player.play()
        let repeatDeadline = Date().addingTimeInterval(3)
        while player.elapsed >= 2 && Date() < repeatDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        player.pause(); XCTAssertEqual(player.current?.id, second.id); XCTAssertLessThan(player.elapsed, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
