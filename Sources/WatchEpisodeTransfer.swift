import SwiftUI
import WatchConnectivity

@MainActor
final class WatchEpisodeTransfer: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchEpisodeTransfer()
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UTubeMusic-WatchTransfers", isDirectory: true)

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        updateAvailability()
    }

    private func updateAvailability() {
        let session = WCSession.default
        ready = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func send(_ episode: Song, library: LibraryStore) async {
        guard ready, !busy else { return }
        let session = WCSession.default
        guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["id"] as? String == episode.id }) else {
            message = "このエピソードは転送待ちです。"; return
        }
        busy = true; message = "音声を準備中…"
        defer { busy = false }
        let file = folder.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let saved = library.song(episode.id), let url = library.file(saved.fileName),
               library.isAvailable(saved), url.pathExtension.lowercased() == "m4a" {
                try FileManager.default.copyItem(at: url, to: file)
            } else {
                let source = try await PythonService.shared.request(["op": "resolve", "id": episode.id])
                guard source.song?.id == episode.id, let value = source.url, let url = URL(string: value),
                      url.scheme == "https", url.host?.hasSuffix(".googlevideo.com") == true else {
                    throw AppFailure("エピソードの音声を取得できませんでした。")
                }
                try await AudioTransfer.download(url: url, headers: source.headers ?? [:], expected: source.bytes ?? 0, to: file) { _ in }
            }
            let duration = try await AudioTiming.read(file).duration
            try Task.checkCancellation()
            updateAvailability()
            guard ready else { throw AppFailure("Watchとの接続を確認してください。") }
            session.transferFile(file, metadata: ["id": episode.id, "title": episode.title,
                                                  "publisher": episode.artist, "duration": duration])
            message = "転送を予約しました。Watchの「エピソード」に届くまでお待ちください。"
        } catch {
            try? FileManager.default.removeItem(at: file)
            message = error.localizedDescription
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            updateAvailability()
            if activationState == .activated {
                let pending = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "m4a" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil &&
                    !busy && !pending.contains(file.lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in updateAvailability() } }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { Task { @MainActor in ready = false } }
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file.fileURL
        Task { @MainActor in
            if file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                try? FileManager.default.removeItem(at: file)
            }
            message = error.map { "Watchへの転送に失敗しました。"+$0.localizedDescription } ?? "Watchへ送信しました。"
        }
    }
}

@MainActor
struct WatchEpisodeSheet: View {
    let episode: Song
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var transfer = WatchEpisodeTransfer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Apple Watchで聴く", systemImage: "applewatch").font(.title2.bold())
            Text(episode.title).font(.headline)
            Text(transfer.ready ? "音声をWatchへ転送すると、iPhoneを持たずに再生できます。" :
                "ペアリングしたApple WatchにUTube Musicを入れてください。").foregroundStyle(Palette.secondary)
            if let message = transfer.message { Text(message).font(.footnote) }
            PrimaryButton(title: "エピソードを送る", symbol: "arrow.down.circle") {
                Task { await transfer.send(episode, library: library) }
            }.disabled(!transfer.ready || transfer.busy)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(Palette.text).background(Palette.background)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
