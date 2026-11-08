import SwiftUI

struct TrackLyrics: Decodable {
    struct Line: Decodable {
        let text: String
        let start: Double
        let end: Double
    }

    let lines: [Line]?
    let text: String?
    let source: String?

    func latestLine(at time: Double) -> Int? {
        lines?.lastIndex { $0.start <= time }
    }

    func activeLine(at time: Double) -> Int? {
        guard let lines, let index = latestLine(at: time), time < lines[index].end else { return nil }
        return index
    }
}

@MainActor
final class LyricsStore: ObservableObject {
    enum State {
        case loading, unavailable, failed
        case loaded(TrackLyrics)
    }

    @Published private var state = State.loading
    private var songID: String?
    private var task: Task<Void, Never>?
    private let request: ([String: String]) async throws -> EngineResponse

    init(request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) }) {
        self.request = request
    }

    deinit { task?.cancel() }

    func state(for id: String) -> State {
        songID == id ? state : .loading
    }

    func load(_ id: String?, retry: Bool = false) {
        guard retry || songID != id else { return }
        task?.cancel()
        songID = id
        state = .loading
        guard let id else { task = nil; return }
        task = Task { [weak self, request] in
            do {
                // Allow quick track changes to settle before using the shared engine.
                try await Task.sleep(for: .milliseconds(300))
                let result = try await request(["op": "lyrics", "id": id])
                try Task.checkCancellation()
                self?.state = result.lyrics.map(State.loaded) ?? .unavailable
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed
            }
        }
    }
}

struct LyricsCard: View {
    let state: LyricsStore.State
    let elapsed: Double
    let expand: () -> Void
    @ScaledMetric(relativeTo: .title3) private var rowHeight: CGFloat = 38

    var body: some View {
        Button(action: expand) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("歌詞").font(.title3.bold())
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.25), in: Circle())
                }
                switch state {
                case .loading:
                    ProgressView("歌詞を取得中…").tint(Palette.text)
                case .unavailable:
                    Text("この音源の歌詞はありません").font(.subheadline)
                case .failed:
                    Text("歌詞を読み込めませんでした").font(.subheadline)
                case .loaded(let lyrics):
                    if let lines = lyrics.lines, !lines.isEmpty {
                        timedPreview(lyrics, lines: lines)
                    } else if let text = lyrics.text {
                        Text("同期なし").font(.caption.bold()).foregroundStyle(Palette.secondary)
                        Text(text).font(.title3.bold()).lineLimit(4)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .foregroundStyle(Palette.text)
            .background(Color(red: 0.29, green: 0.18, blue: 0.24), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("タップで歌詞を全画面表示")
        .accessibilityIdentifier("now-playing-lyrics")
    }

    private func timedPreview(_ lyrics: TrackLyrics, lines: [TrackLyrics.Line]) -> some View {
        let active = lyrics.activeLine(at: elapsed)
        let first = min(lyrics.latestLine(at: elapsed) ?? 0, max(0, lines.count - 3))
        let visible = first..<min(first + 3, lines.count)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(visible, id: \.self) { index in
                Text(lines[index].text)
                    .font(.title3.bold())
                    .foregroundStyle(index == active ? Palette.text : Palette.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: first)
        .clipped()
    }
}

struct LyricsView: View {
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var lyrics: LyricsStore

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                IconButton(symbol: "chevron.down", label: "歌詞を閉じる") { dismiss() }
                Spacer()
                if let song = player.current {
                    VStack(spacing: 3) {
                        Text(song.title).font(.headline).lineLimit(1)
                        Text(song.artist).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer()
                    IconButton(symbol: player.playbackButtonSymbol, label: player.playbackButtonLabel) { player.toggle() }
                }
            }.padding(.horizontal, 14)
            if let song = player.current, song.hasYouTubeSource {
                TrackLyricsView(state: lyrics.state(for: song.id), retry: { lyrics.load(song.id, retry: true) })
                    .id(song.id)
            } else {
                EmptyPanel(symbol: "quote.bubble", title: "歌詞がありません", detail: "歌詞を取得できる曲を再生してください。")
                    .frame(maxHeight: .infinity)
            }
        }
        .foregroundStyle(Palette.text)
        .background(LinearGradient(colors: [Color(red: 0.28, green: 0.17, blue: 0.23), Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .onChange(of: player.lyricsSongID, initial: true) { _, id in lyrics.load(id) }
        .appFeedback()
    }
}

private struct TrackLyricsView: View {
    let state: LyricsStore.State
    let retry: () -> Void
    @EnvironmentObject private var player: PlayerStore
    @State private var followsPlayback = true

    var body: some View {
        switch state {
        case .loading:
            ProgressView("歌詞を取得中…").tint(Palette.accent).frame(maxHeight: .infinity)
        case .failed:
            VStack {
                EmptyPanel(symbol: "wifi.exclamationmark", title: "歌詞を読み込めませんでした", detail: "通信を確認して再試行してください。")
                TextActionButton("再試行", action: retry)
            }.frame(maxHeight: .infinity)
        case .unavailable:
            EmptyPanel(symbol: "quote.bubble", title: "歌詞がありません", detail: "この音源の歌詞はYouTube Musicから取得できませんでした。")
                .frame(maxHeight: .infinity)
        case .loaded(let lyrics):
            if let lines = lyrics.lines, !lines.isEmpty {
                timedLyrics(lyrics, lines: lines)
            } else if let text = lyrics.text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("同期なし").font(.caption.bold()).foregroundStyle(Palette.secondary)
                        Text(text).font(.title3.weight(.semibold)).lineSpacing(7)
                        source(lyrics.source)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            }
        }
    }

    private func timedLyrics(_ lyrics: TrackLyrics, lines: [TrackLyrics.Line]) -> some View {
        let active = lyrics.activeLine(at: player.elapsed)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(lines.indices, id: \.self) { index in
                        Button { player.seek(lines[index].start); followsPlayback = true } label: {
                            Text(lines[index].text)
                                .font(.title2.bold())
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(index == active ? Palette.text : Palette.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(index)
                            .disabled(player.resolvingOnline)
                            .accessibilityAddTraits(index == active ? .isSelected : [])
                    }
                    source(lyrics.source)
                }.padding(24)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 15).onChanged { _ in followsPlayback = false })
            .onChange(of: active, initial: true) { _, index in
                if followsPlayback, let index { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) } }
            }
            .safeAreaInset(edge: .bottom) {
                if !followsPlayback {
                    TextActionButton("再生位置に戻る") {
                        followsPlayback = true
                        withAnimation { proxy.scrollTo(active ?? 0, anchor: .center) }
                    }.padding(.horizontal, 18)
                        .background(Palette.raised, in: Capsule())
                        .padding(8)
                }
            }
        }
    }

    @ViewBuilder private func source(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text(value).font(.caption).foregroundStyle(Palette.secondary).padding(.top, 12)
        }
    }
}
