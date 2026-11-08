import Foundation
import AVFoundation
import UIKit

struct EngineSong: Decodable {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    let thumbnail: String?
    var song: Song { Song(id: id, title: title, artist: artist, duration: duration, thumbnail: thumbnail) }
}
struct EngineResponse: Decodable {
    let ok: Bool
    let error: String?
    let songs: [EngineSong]?
    let song: EngineSong?
    let url: String?
    let headers: [String: String]?
    let bytes: Int64?
    let has_more: Bool?
    let next_offset: Int?
    let sections: [CatalogSection]?
    let items: [CatalogItem]?
    let collection: CatalogItem?
    let unavailable: Int?
    let suggestions: [String]?
    let preview_start: Double?
    let preview_end: Double?
    let preview_kind: String?
    let loudness_db: Double?
    let audio_duration: Double?
    let lyrics: TrackLyrics?
}

final class PythonService {
    static let shared = PythonService()
    private let worker = DispatchQueue(label: "local.utubemusic.python", qos: .userInitiated)
    func request(_ values: [String: String]) async throws -> EngineResponse {
        let data = try JSONSerialization.data(withJSONObject: values)
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    guard let path = Bundle.main.resourcePath else {
                        throw AppFailure("音声取得エンジンを読み込めません。")
                    }
                    let output = try MusicPythonBridge.call(text, resourcePath: path)
                    let response = try JSONDecoder().decode(EngineResponse.self, from: Data(output.utf8))
                    guard response.ok else { throw AppFailure(response.error ?? "曲を取得できませんでした。") }
                    continuation.resume(returning: response)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct SaveJob: Identifiable {
    let id: UUID
    var song: Song
    var fraction: Double = 0
    var phase = "保存待ち"
    var error: String?
    var finished = false
    var playlistIDs: Set<UUID> = []
}

@MainActor
final class MusicService: ObservableObject {
    @Published var jobs: [SaveJob] = []
    @Published private(set) var repairing = false
    @Published private(set) var repairProgress: String?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let engine = PythonService.shared
    let library: LibraryStore
    init(library: LibraryStore) { self.library = library }

    func save(_ song: Song, favorite: Bool, playlistIDs: Set<UUID>) {
        if let existing = library.song(song.id), library.isAvailable(existing) {
            do {
                var updated = existing
                updated.favorite = favorite || existing.favorite
                try library.save(updated, playlistIDs: playlistIDs)
                library.message = "保存済みの曲に選択した追加先を反映しました。"
            } catch { library.message = error.localizedDescription }
            return
        }
        guard !library.recoveryNeeded else { library.message = "ライブラリの復元が必要です。"; return }
        if let index = jobs.firstIndex(where: { $0.song.id == song.id && !$0.finished && $0.error == nil }) {
            jobs[index].playlistIDs.formUnion(playlistIDs)
            jobs[index].song.favorite = jobs[index].song.favorite || favorite
            library.message = "保存中の曲に、選んだ追加先を反映しました。"; return
        }
        let id = UUID()
        var song = song; song.favorite = favorite
        jobs.append(SaveJob(id: id, song: song, playlistIDs: playlistIDs))
        scheduleNext()
    }
    func cancel(_ id: UUID) {
        if let task = tasks[id] { task.cancel() }
        else { update(id) { $0.error = "保存をキャンセルしました" } }
    }
    func cancelPending() {
        for job in jobs where !job.finished && job.error == nil { cancel(job.id) }
    }
    private func scheduleNext() {
        guard !repairing, tasks.isEmpty, let job = jobs.first(where: { !$0.finished && $0.error == nil }) else { return }
        tasks[job.id] = Task { await perform(job.id) }
    }
    func repairSavedSongs() async {
        guard !repairing else { return }
        guard tasks.isEmpty else { library.message = "曲の保存が終わってから修復してください。"; return }
        guard !library.recoveryNeeded else { library.message = "ライブラリの復元が必要です。"; return }
        repairing = true
        defer { repairing = false; scheduleNext() }
        let candidates = library.songs.filter { !$0.id.hasPrefix("local-") && $0.audioTimingVersion != 1 }
        var repaired = 0
        var failures: [String] = []
        for (index, song) in candidates.enumerated() {
            repairProgress = "\(index + 1) / \(candidates.count)曲：\(song.title)"
            do {
                try Task.checkCancellation()
                guard let originalName = song.fileName, let source = library.file(originalName), library.isAvailable(song) else {
                    throw AppFailure("音声ファイルが見つかりません。")
                }
                let timing = try await AudioTiming.read(source)
                try Task.checkCancellation()
                try library.updateAudioDuration(song.id, expectedFileName: originalName, duration: timing.duration)
                repaired += 1
            } catch {
                failures.append(song.title + "：" + error.localizedDescription)
                if Task.isCancelled { break }
            }
        }
        repairProgress = nil
        library.message = candidates.isEmpty ? "修復が必要な曲はありません。" : "\(repaired)曲の再生時間を修復しました。" +
            (failures.isEmpty ? "" : "\n修復できなかった曲は元のまま保持しています。\n" + failures.joined(separator: "\n"))
    }
    func saveCollection(_ songs: [Song], title: String, sourceID: String, favorite: Bool, download: Bool = true) throws {
        guard !songs.isEmpty else { throw AppFailure("保存できる曲がありません。") }
        // Reuse only the same imported source; a user's equally named list is separate.
        let playlistID = try library.playlists.first(where: { $0.sourceID == sourceID })?.id ?? library.createPlaylist(title)
        try library.setSourceOrder(songs.map(\.id), sourceID: sourceID, for: playlistID)
        for song in songs {
            if !download { try library.addOnline(song, favorite: favorite, playlistIDs: [playlistID]); continue }
            if let index = jobs.firstIndex(where: { $0.song.id == song.id && !$0.finished && $0.error == nil }) {
                jobs[index].playlistIDs.insert(playlistID)
                jobs[index].song.favorite = jobs[index].song.favorite || favorite
            } else { save(song, favorite: favorite, playlistIDs: [playlistID]) }
        }
        if !download { library.message = "曲を追加しました。再生には通信が必要です。"; return }
        let remaining = songs.filter { library.song($0.id).map(library.isAvailable) != true }.count
        library.message = remaining == 0 ? "\(songs.count)曲を「\(title)」に追加しました。すべて保存済みです。" : "「\(title)」にまとめます。未保存の\(remaining)曲は順番に保存します。"
    }
    func dismiss(_ id: UUID) { guard tasks[id] == nil else { return }; jobs.removeAll { $0.id == id } }
    func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.error != nil else { return }
        jobs.removeAll { $0.id == id }
        save(job.song, favorite: job.song.favorite, playlistIDs: job.playlistIDs)
    }
    private func update(_ id: UUID, _ body: (inout SaveJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[i]) }
    }
    private func perform(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let fileName = UUID().uuidString + ".m4a"
        let destination = library.root.appendingPathComponent(fileName)
        var artworkName: String?
        // Extraction requires the foreground. This assertion only grants a short grace period.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Finish saving music") { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
        defer {
            tasks[id] = nil
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            scheduleNext()
        }
        do {
            try Task.checkCancellation()
            update(id) { $0.phase = "音声を確認中" }
            let response = try await engine.request(["op": "resolve", "id": job.song.id])
            try Task.checkCancellation()
            guard let urlString = response.url, let url = URL(string: urlString),
                  url.scheme == "https", let host = url.host, host.hasSuffix(".googlevideo.com"),
                  let metadata = response.song else { throw AppFailure("音声の保存先を確認できませんでした。") }
            update(id) { $0.phase = "曲を保存中" }
            try await AudioTransfer.download(url: url, headers: response.headers ?? [:], expected: response.bytes ?? 0, to: destination) { [weak self] progress in
                Task { @MainActor in self?.update(id) { $0.fraction = progress } }
            }
            try Task.checkCancellation()
            update(id) { $0.phase = "音声の再生時間を確認中" }
            let duration = try await AudioTiming.read(destination).duration
            if metadata.duration.isFinite, metadata.duration > 0,
               abs(duration - metadata.duration) > max(2, metadata.duration * 0.02) {
                throw AppFailure("取得元の曲と音声の長さが一致しません。再試行してください。")
            }
            if let thumbnail = metadata.thumbnail, let url = URL(string: thumbnail), url.scheme == "https" {
                // Artwork failure must not prevent listening. Cache it for offline use.
                artworkName = await cacheArtwork(url, id: job.song.id)
            }
            try Task.checkCancellation()
            var song = metadata.song
            song.sourceLoudnessDB = response.loudness_db
            let latest = jobs.first(where: { $0.id == id }) ?? job
            song.favorite = latest.song.favorite; song.duration = duration
            song.fileName = fileName; song.artworkName = artworkName
            song.audioTimingVersion = 1
            song.bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            try library.save(song, playlistIDs: latest.playlistIDs)
            update(id) { $0.song = song; $0.fraction = 1; $0.phase = "保存しました"; $0.finished = true }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let artworkName, let artwork = library.file(artworkName) { try? FileManager.default.removeItem(at: artwork) }
            update(id) { $0.error = error is CancellationError || (error as? URLError)?.code == .cancelled ? "保存をキャンセルしました" : error.localizedDescription }
        }
    }
    private func cacheArtwork(_ url: URL, id: String) async -> String? {
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count < 8_000_000, let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.85) else { return nil }
            let name = UUID().uuidString + ".jpg"
            try jpg.write(to: library.root.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }
}

enum AudioTransfer {
    // Bounded range requests avoid a single throttled googlevideo GET. Never persist an expired URL.
    static func download(url: URL, headers: [String: String], expected: Int64, to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let limit: Int64 = 1_000_000_000
        guard expected <= limit else { throw AppFailure("この曲は1GBを超えるため保存できません。") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 300
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var offset: Int64 = 0
        var total = expected
        let chunk: Int64 = 1_048_576
        repeat {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let end = total > 0 ? min(total - 1, offset + chunk - 1) : offset + chunk - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
                  http.url?.scheme == "https", http.url?.host?.hasSuffix(".googlevideo.com") == true else {
                throw AppFailure("曲の転送に失敗しました。もう一度保存すると取得先を更新します。")
            }
            guard !(http.mimeType ?? "").contains("text"), !(http.mimeType ?? "").contains("json") else {
                throw AppFailure("取得元が音声データを返しませんでした。")
            }
            let received = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard received > 0, offset + received <= limit else { throw AppFailure("音声データのサイズを確認できませんでした。") }
            if http.statusCode == 206 {
                guard let range = http.value(forHTTPHeaderField: "Content-Range"), let parsed = parseRange(range),
                      parsed.start == offset, parsed.end - parsed.start + 1 == received,
                      parsed.total > parsed.end, total == 0 || total == parsed.total else {
                    throw AppFailure("曲の転送順序を確認できませんでした。再試行してください。")
                }
                total = parsed.total
                guard total <= limit else { throw AppFailure("この曲は1GBを超えるため保存できません。") }
            } else {
                guard offset == 0, total == 0 || total == received else { throw AppFailure("曲の転送が途中で途切れました。") }
                total = received
            }
            let input = try FileHandle(forReadingFrom: temporary)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
            offset += received
            progress(total > 0 ? Double(offset) / Double(total) : 0)
        } while offset < total
        guard offset > 0, offset == total else { throw AppFailure("音声の保存が完了しませんでした。") }
    }
    static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        let decimal: (Substring) -> Bool = { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
        guard bounds.count == 2, decimal(bounds[0]), decimal(bounds[1]), decimal(fields[1]),
              let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(fields[1]),
              start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
}
