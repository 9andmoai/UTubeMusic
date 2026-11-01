import Foundation
import AVFoundation

struct DownloadRemovalReport {
    var removed: [String] = []
    var failures: [String] = []
    var cancelled = false
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published var message: String?
    @Published private(set) var recoveryNeeded = false
    let root: URL
    private let database: URL
    private let fm = FileManager.default
    private let removeDownloadedFile: (URL) throws -> Void

    init(root: URL? = nil, removeDownloadedFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.removeDownloadedFile = removeDownloadedFile
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTubeMusic", isDirectory: true)
        database = self.root.appendingPathComponent("library.json")
        do {
            try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: database.path) {
                let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: database))
                guard snapshot.version == 1 else { throw AppFailure("このライブラリは新しいバージョン用です。アプリを更新してください。") }
                guard Set(snapshot.songs.map(\.id)).count == snapshot.songs.count,
                      Set(snapshot.playlists.map(\.id)).count == snapshot.playlists.count else {
                    throw AppFailure("ライブラリ内に重複したIDがあります。バックアップを確認してください。")
                }
                songs = snapshot.songs; playlists = snapshot.playlists
            }
        } catch {
            recoveryNeeded = true
            message = "ライブラリを読み込めません。元のファイルを保護しています。ファイルアプリでバックアップを確認してください。\n\(error.localizedDescription)"
        }
    }
    var favorites: [Song] { songs.filter(\.favorite) }
    var totalBytes: Int64 { songs.reduce(0) { $0 + $1.bytes } }
    func song(_ id: String) -> Song? { songs.first { $0.id == id } }
    func songs(in playlist: MusicPlaylist) -> [Song] { playlist.songIDs.compactMap(song) }
    func file(_ name: String?) -> URL? {
        guard let name, !name.isEmpty, name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".", name != ".." else { return nil }
        return root.appendingPathComponent(name)
    }
    func isAvailable(_ song: Song) -> Bool {
        guard let url = file(song.fileName) else { return false }
        return fm.fileExists(atPath: url.path)
    }
    func isPlayable(_ song: Song) -> Bool { isAvailable(song) || song.onlineOnly == true }
    func canRemoveDownload(_ song: Song) -> Bool {
        song.id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil && song.fileName != nil
    }
    func removeDownload(_ id: String) throws {
        guard let original = song(id), canRemoveDownload(original), let name = original.fileName,
              let url = file(name), ["m4a", "mp3", "aac", "wav", "aif", "aiff", "caf"].contains(url.pathExtension.lowercased()),
              name != original.artworkName else {
            throw AppFailure("YouTubeから保存した曲のダウンロードだけを削除できます。読み込んだ音声ファイルはオンラインに切り替えられません。")
        }
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AppFailure("音声ファイルの状態を確認できません。削除を中止しました。") }
        }
        // Persist the online registration before deleting any audio. A failed index
        // write must leave the playable download and all memberships untouched.
        try commit {
            if let index = songs.firstIndex(where: { $0.id == id }) {
                songs[index].fileName = nil
                songs[index].bytes = 0
                songs[index].onlineOnly = true
                songs[index].audioTimingVersion = nil
            }
        }
        guard !songs.contains(where: { $0.fileName == name }), fm.fileExists(atPath: url.path) else { return }
        do { try removeDownloadedFile(url) }
        catch {
            do { try commit { if let index = songs.firstIndex(where: { $0.id == id }) { songs[index] = original } } }
            catch { throw AppFailure("音声ファイルの削除と登録情報の復元に失敗しました。音声ファイルは残っています。ファイルアプリで確認してください。") }
            throw AppFailure("音声ファイルを削除できなかったため、ダウンロード済みの状態に戻しました。")
        }
    }
    func removeDownloads(_ ids: [String], didRemove: (String) -> Void = { _ in },
                         progress: (Int, Int) -> Void = { _, _ in }) async -> DownloadRemovalReport {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        var result = DownloadRemovalReport()
        for (index, id) in unique.enumerated() {
            guard !Task.isCancelled else { result.cancelled = true; break }
            do {
                try removeDownload(id)
                result.removed.append(id)
                didRemove(id)
            } catch { result.failures.append("\(song(id)?.title ?? id)：\(error.localizedDescription)") }
            progress(index + 1, unique.count)
            // Commit and remove one file at a time, allowing cancellation without
            // losing the memberships of completed, failed or remaining songs.
            await Task.yield()
        }
        return result
    }
    func cacheLoudness(_ id: String, fileName: String, lufs: Double?) throws {
        guard song(id)?.fileName == fileName, lufs == nil || (lufs!.isFinite && (-70...10).contains(lufs!)) else { return }
        try commit {
            if let i = songs.firstIndex(where: { $0.id == id }) {
                songs[i].measuredLoudness = lufs; songs[i].loudnessFileName = fileName
            }
        }
    }
    func cacheSourceLoudness(_ id: String, db: Double?) throws {
        guard let db, db.isFinite, (-60...60).contains(db), song(id)?.sourceLoudnessDB != db else { return }
        try commit { if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].sourceLoudnessDB = db } }
    }
    func setIntroSkip(_ id: String, seconds: Double) throws {
        guard let song = song(id), seconds.isFinite, (0...30).contains(seconds),
              song.duration <= 0 || seconds <= max(0, song.duration - 0.5) else {
            throw AppFailure("開始位置は曲の終わりより手前の0〜30秒で指定してください。")
        }
        try commit { if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].introSkipSeconds = seconds } }
    }
    func addOnline(_ song: Song, favorite: Bool, playlistIDs: Set<UUID>) throws {
        var value = self.song(song.id) ?? song
        if !isAvailable(value) { value.onlineOnly = true }
        value.favorite = value.favorite || favorite
        try save(value, playlistIDs: playlistIDs)
    }
    func save(_ song: Song, playlistID: UUID?) throws {
        try save(song, playlistIDs: Set(playlistID.map { [$0] } ?? []))
    }
    func save(_ song: Song, playlistIDs: Set<UUID>) throws {
        try commit {
            if let i = songs.firstIndex(where: { $0.id == song.id }) {
                var updated = song
                updated.favorite = song.favorite || songs[i].favorite
                updated.introSkipSeconds = song.introSkipSeconds ?? songs[i].introSkipSeconds
                songs[i] = updated
            } else { songs.insert(song, at: 0) }
            for i in playlists.indices where playlistIDs.contains(playlists[i].id) {
                if !playlists[i].songIDs.contains(song.id) { playlists[i].songIDs.append(song.id) }
                if let order = playlists[i].sourceOrder {
                    let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
                    playlists[i].songIDs = playlists[i].songIDs.enumerated().sorted {
                        let left = rank[$0.element] ?? Int.max, right = rank[$1.element] ?? Int.max
                        return left == right ? $0.offset < $1.offset : left < right
                    }.map(\.element)
                }
            }
        }
    }
    func setSourceOrder(_ ids: [String], sourceID: String, for playlistID: UUID) throws {
        try commit {
            if let i = playlists.firstIndex(where: { $0.id == playlistID }) {
                playlists[i].sourceOrder = ids; playlists[i].sourceID = sourceID
            }
        }
    }
    /// Only update the index. Repair never writes, replaces, or deletes audio files.
    func updateAudioDuration(_ id: String, expectedFileName: String, duration: Double) throws {
        guard duration.isFinite, duration > 0, let current = song(id), current.fileName == expectedFileName else {
            throw AppFailure("曲の状態が変わったため再生時間の更新を中止しました。")
        }
        try commit {
            if let index = songs.firstIndex(where: { $0.id == id }) {
                songs[index].duration = duration
                songs[index].audioTimingVersion = 1
            }
        }
    }
    @discardableResult func createPlaylist(_ name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppFailure("プレイリスト名を入力してください。") }
        let playlist = MusicPlaylist(name: String(name.prefix(100)))
        try commit { playlists.insert(playlist, at: 0) }
        return playlist.id
    }
    func renamePlaylist(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppFailure("プレイリスト名を入力してください。") }
        try commit { if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].name = String(name.prefix(100)) } }
    }
    func deletePlaylist(_ id: UUID) throws { try commit { playlists.removeAll { $0.id == id } } }
    func toggleFavorite(_ id: String) {
        do { try commit { if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].favorite.toggle() } } }
        catch { message = error.localizedDescription }
    }
    func add(_ id: String, to playlistID: UUID) throws {
        guard song(id) != nil else { throw AppFailure("保存済みの曲を選んでください。") }
        try commit {
            if let i = playlists.firstIndex(where: { $0.id == playlistID }), !playlists[i].songIDs.contains(id) { playlists[i].songIDs.append(id) }
        }
    }
    func remove(_ id: String, from playlistID: UUID) throws {
        try commit { if let i = playlists.firstIndex(where: { $0.id == playlistID }) { playlists[i].songIDs.removeAll { $0 == id } } }
    }
    func move(in playlistID: UUID, from: IndexSet, to: Int) throws {
        try commit {
            guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
            var ids = playlists[i].songIDs
            let moving = from.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
            for index in from.sorted(by: >) where ids.indices.contains(index) { ids.remove(at: index) }
            let destination = min(ids.count, max(0, to - from.filter { $0 < to }.count))
            ids.insert(contentsOf: moving, at: destination)
            playlists[i].songIDs = ids
            playlists[i].sourceOrder = nil
        }
    }
    func delete(_ song: Song) throws {
        // Commit the index first. A failed database write must never lose the audio file.
        try commit {
            songs.removeAll { $0.id == song.id }
            for i in playlists.indices { playlists[i].songIDs.removeAll { $0 == song.id } }
        }
        for name in [song.fileName, song.artworkName] {
            if let url = file(name), fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { message = "曲の登録は削除しましたが、ファイルの削除に失敗しました：\(error.localizedDescription)" }
            }
        }
    }
    func importAudio(_ url: URL) async throws {
        guard !recoveryNeeded else { throw AppFailure("ライブラリの復元が必要です。") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "mp3", "aac", "wav", "aif", "aiff", "caf"].contains(ext) else { throw AppFailure("M4A・MP3などの音声ファイルを選んでください。") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, try await asset.load(.isPlayable) else { throw AppFailure("この音声を再生できません。") }
        let id = "local-" + UUID().uuidString
        let name = id + "." + ext
        let target = root.appendingPathComponent(name)
        try fm.copyItem(at: url, to: target)
        do {
            let bytes = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            try save(Song(id: id, title: url.deletingPathExtension().lastPathComponent, artist: "読み込んだ曲", duration: duration, fileName: name, bytes: bytes), playlistID: nil)
        } catch { try? fm.removeItem(at: target); throw error }
    }
    private func commit(_ mutation: () -> Void) throws {
        guard !recoveryNeeded else { throw AppFailure("元のライブラリを保護しています。復元してから操作してください。") }
        let oldSongs = songs, oldPlaylists = playlists
        mutation()
        do {
            let data = try JSONEncoder().encode(LibrarySnapshot(songs: songs, playlists: playlists))
            if fm.fileExists(atPath: database.path) {
                // The previous valid index remains available alongside the audio in Files.
                try Data(contentsOf: database).write(to: root.appendingPathComponent("library.previous.json"), options: .atomic)
            }
            try data.write(to: database, options: .atomic)
        } catch { songs = oldSongs; playlists = oldPlaylists; throw error }
    }
}
