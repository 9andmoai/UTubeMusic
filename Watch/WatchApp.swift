import SwiftUI
import AVFoundation
import WatchConnectivity

private struct Episode: Codable, Identifiable {
    let id: String
    let file: String
    let title: String
    let publisher: String
    let duration: Double
}

@MainActor
private final class WatchPlayer: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var current: Episode?
    @Published private(set) var playing = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var error: String?
    private let player = AVPlayer()
    private var observer: Any?
    private var finished: NSObjectProtocol?
    private var queue: [Episode] = []
    private var generation = UUID()

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Episodes", isDirectory: true)
    }

    override init() {
        super.init()
        reload()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let position = self.player.currentTime().seconds
                if position.isFinite { self.elapsed = position }
                self.playing = self.player.rate > 0
            }
        }
        finished = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.next()
            }
        }
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        episodes = files.filter { $0.pathExtension == "json" }.sorted {
            let key = Set([URLResourceKey.contentModificationDateKey])
            let left = (try? $0.resourceValues(forKeys: key).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: key).contentModificationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left > right
        }.compactMap {
            guard let data = try? Data(contentsOf: $0), let episode = try? JSONDecoder().decode(Episode.self, from: data),
                  UUID(uuidString: episode.file) != nil,
                  FileManager.default.fileExists(atPath: audio(episode).path) else { return nil }
            return episode
        }
    }

    private func audio(_ episode: Episode) -> URL {
        Self.folder.appendingPathComponent(episode.file + ".m4a")
    }

    func start(_ episode: Episode) {
        queue = Array(episodes.drop(while: { $0.id != episode.id }))
        load(episode)
    }

    private func load(_ episode: Episode) {
        player.pause()
        current = episode; elapsed = 0; playing = false
        player.replaceCurrentItem(with: AVPlayerItem(url: audio(episode)))
        resume()
    }

    private func resume() {
        error = nil
        let token = UUID(); generation = token
        Task {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                let activated = try await session.activate()
                guard generation == token else { return }
                if activated { player.play(); playing = true }
                else { error = "音声の出力先を選んでください。" }
            } catch {
                if generation == token { self.error = error.localizedDescription }
            }
        }
    }

    func toggle() {
        if playing { generation = UUID(); player.pause(); playing = false }
        else {
            if let current, elapsed >= current.duration - 0.1 { player.seek(to: .zero) }
            resume()
        }
    }

    func seek(_ offset: Double) {
        guard let current else { return }
        let seconds = min(current.duration, max(0, elapsed + offset))
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func next() {
        if !queue.isEmpty { queue.removeFirst() }
        if let next = queue.first { load(next) }
        else { generation = UUID(); player.pause(); playing = false }
    }

    func delete(_ episode: Episode) {
        if current?.id == episode.id {
            generation = UUID(); player.pause(); player.replaceCurrentItem(with: nil)
            current = nil; playing = false; elapsed = 0
        }
        queue.removeAll { $0.id == episode.id }
        let info = Self.folder.appendingPathComponent(episode.id + ".json")
        do {
            try FileManager.default.removeItem(at: info)
            try? FileManager.default.removeItem(at: audio(episode))
            reload()
        } catch { self.error = error.localizedDescription }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata, let id = metadata["id"] as? String,
              id.range(of: "\\A[A-Za-z0-9_-]{11}\\z", options: .regularExpression) != nil,
              let title = metadata["title"] as? String, let publisher = metadata["publisher"] as? String,
              let duration = metadata["duration"] as? Double, duration.isFinite, duration > 0 else { return }
        let name = UUID().uuidString
        let episode = Episode(id: id, file: name, title: title, publisher: publisher, duration: duration)
        let info = Self.folder.appendingPathComponent(id + ".json")
        let audio = Self.folder.appendingPathComponent(name + ".m4a")
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // Keep the first successfully transferred copy if the sender retries.
            if FileManager.default.fileExists(atPath: info.path) { return }
            try FileManager.default.moveItem(at: file.fileURL, to: audio)
            try JSONEncoder().encode(episode).write(to: info, options: .atomic)
            Task { @MainActor in reload() }
        } catch {
            try? FileManager.default.removeItem(at: audio)
            Task { @MainActor in self.error = "エピソードを保存できませんでした。" }
        }
    }
}

@main
@MainActor
struct UTubeMusicWatchApp: App {
    @StateObject private var store = WatchPlayer()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    if store.current != nil {
                        NavigationLink { player } label: { Label("再生中", systemImage: "waveform") }
                    }
                    if store.episodes.isEmpty {
                        Text("iPhoneの番組ページからエピソードを送信").font(.footnote)
                    }
                    ForEach(store.episodes) { episode in
                        NavigationLink {
                            player.onAppear { if store.current?.id != episode.id { store.start(episode) } }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(episode.title).lineLimit(2)
                                Text(episode.publisher).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("削除", role: .destructive) { store.delete(episode) } }
                    }
                    if let error = store.error { Text(error).font(.footnote) }
                }.navigationTitle("エピソード")
            }
        }
    }

    private var player: some View {
        VStack(spacing: 10) {
            Text(store.current?.title ?? "").font(.headline).lineLimit(3)
            if let episode = store.current {
                ProgressView(value: min(episode.duration, store.elapsed), total: episode.duration)
            }
            HStack {
                Button { store.seek(-15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("15秒戻る")
                Button { store.toggle() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(store.playing ? "一時停止" : "再生")
                Button { store.seek(30) } label: { Image(systemName: "goforward.30") }.accessibilityLabel("30秒進む")
            }
            Button("次のエピソード") { store.next() }.font(.footnote)
            if let error = store.error { Text(error).font(.caption2) }
        }.padding(.horizontal, 4)
    }
}
