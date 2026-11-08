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

    func activeLine(at time: Double) -> Int? {
        guard let lines, let index = lines.lastIndex(where: { $0.start <= time }),
              time < lines[index].end else { return nil }
        return index
    }
}

struct LyricsView: View {
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    var request: ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) }

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
                TrackLyricsView(songID: song.id, request: request).id(song.id)
            } else {
                EmptyPanel(symbol: "quote.bubble", title: "歌詞がありません", detail: "歌詞を取得できる曲を再生してください。")
                    .frame(maxHeight: .infinity)
            }
        }
        .foregroundStyle(Palette.text)
        .background(LinearGradient(colors: [Color(red: 0.28, green: 0.17, blue: 0.23), Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .appFeedback()
    }
}

private struct TrackLyricsView: View {
    let songID: String
    let request: ([String: String]) async throws -> EngineResponse
    @EnvironmentObject private var player: PlayerStore
    @State private var lyrics: TrackLyrics?
    @State private var loading = true
    @State private var failed = false
    @State private var requestID = UUID()
    @State private var followsPlayback = true

    var body: some View {
        Group {
            if loading {
                ProgressView("歌詞を取得中…").tint(Palette.accent).frame(maxHeight: .infinity)
            } else if failed {
                VStack {
                    EmptyPanel(symbol: "wifi.exclamationmark", title: "歌詞を読み込めませんでした", detail: "通信を確認して再試行してください。")
                    TextActionButton("再試行") { requestID = UUID() }
                }.frame(maxHeight: .infinity)
            } else if let lyrics, let lines = lyrics.lines, !lines.isEmpty {
                timedLyrics(lyrics, lines: lines)
            } else if let lyrics, let text = lyrics.text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("同期なし").font(.caption.bold()).foregroundStyle(Palette.secondary)
                        Text(text).font(.title3.weight(.semibold)).lineSpacing(7)
                        source(lyrics.source)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            } else {
                EmptyPanel(symbol: "quote.bubble", title: "歌詞がありません", detail: "この音源の歌詞はYouTube Musicから取得できませんでした。")
                    .frame(maxHeight: .infinity)
            }
        }
        .task(id: requestID) {
            loading = true
            failed = false
            do {
                let result = try await request(["op": "lyrics", "id": songID])
                try Task.checkCancellation()
                lyrics = result.lyrics
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            loading = false
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
