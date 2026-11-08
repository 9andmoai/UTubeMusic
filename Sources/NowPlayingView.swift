import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var position: Double = 0
    @State private var scrubbing = false
    @State private var showQueue = false
    @State private var showActions = false
    @State private var showLyrics = false
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        IconButton(symbol: "chevron.down", label: "再生画面を閉じる") { dismiss() }
                        Spacer()
                        VStack(spacing: 4) {
                            Text("NOW PLAYING").font(.system(size: 10, weight: .bold)).tracking(2.2)
                            Text(player.searchPlayback ? "検索結果" : "このiPhoneのライブラリ").font(.caption2).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        IconButton(symbol: "ellipsis", label: "曲のメニュー") { showActions = true }
                    }
                    if let song = player.current {
                        SongArtwork(song: song, size: min(geo.size.width - 48, min(max(160, geo.size.height * 0.36), 360)), radius: 16)
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 16).padding(.vertical, 6)
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(song.title).font(.system(size: 25, weight: .bold)).tracking(-0.7).lineLimit(2)
                                Text(song.artist).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            let favorite = library.song(song.id)?.favorite == true
                            IconButton(symbol: favorite ? "heart.fill" : "heart", label: favorite ? "お気に入りから外す" : "お気に入りに追加", color: favorite ? Palette.accent : Palette.text, size: 24) { library.toggleFavorite(song) }
                        }
                        VStack(spacing: 0) {
                            Slider(value: $position, in: 0...max(1, player.duration)) { editing in
                                scrubbing = editing
                                if !editing { player.seek(position) }
                            }.tint(Palette.text).accessibilityLabel("曲の再生位置")
                            HStack {
                                Text(Song.clock(position)); Spacer(); Text(Song.clock(player.duration))
                            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                        }
                        HStack(spacing: 0) {
                            IconButton(symbol: "shuffle", label: player.queue.shuffled ? "シャッフルをオフ" : "シャッフルをオン", color: player.queue.shuffled ? Palette.accent : Palette.secondary) { player.toggleShuffle() }
                            Spacer(minLength: 0)
                            IconButton(symbol: "backward.end.fill", label: "前の曲", size: 29) { player.previous() }
                            Spacer(minLength: 0)
                            Button { player.toggle() } label: {
                                Image(systemName: player.playbackButtonSymbol)
                                    .font(.system(size: 29, weight: .semibold)).offset(x: player.playbackButtonSymbol == "pause.fill" ? 0 : 2)
                                    .foregroundStyle(.black).frame(width: 76, height: 76).background(Palette.text, in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel(player.playbackButtonLabel)
                            Spacer(minLength: 0)
                            IconButton(symbol: "forward.end.fill", label: "次の曲", size: 29) { player.next() }
                            Spacer(minLength: 0)
                            IconButton(symbol: player.queue.repeatMode.symbol, label: player.queue.repeatMode.label + "・切り替え", color: player.queue.repeatMode == .off ? Palette.secondary : Palette.accent) { player.toggleRepeat() }
                        }
                        HStack {
                            Label(library.isAvailable(song) ? "オフラインで再生" : player.resolvingOnline ? "再生を準備中…" : player.buffering ? "通信待ち…" : "オンラインで再生", systemImage: library.isAvailable(song) ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(Palette.secondary)
                            Spacer()
                            IconButton(symbol: "list.bullet", label: "再生キュー") { showQueue = true }
                        }.padding(.top, 4)
                        if song.hasYouTubeSource {
                            Button { showLyrics = true } label: {
                                HStack {
                                    Label("歌詞", systemImage: "quote.bubble").font(.title3.bold())
                                    Spacer()
                                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.subheadline)
                                }.padding(18).frame(minHeight: 64).contentShape(Rectangle())
                                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).accessibilityLabel("歌詞を開く")
                        }
                    } else {
                        EmptyPanel(symbol: "music.note", title: "再生する曲を選んでください", detail: "保存した曲をライブラリから選べます。")
                    }
                }.padding(.horizontal, 24).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(Palette.text)
            .background(LinearGradient(colors: [Color(red: 0.27, green: 0.19, blue: 0.22), Palette.background, Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
            .onAppear { position = player.elapsed }
            .onChange(of: player.elapsed) { _, value in if !scrubbing { position = value } }
            .sheet(isPresented: $showQueue) { QueueView() }
            .sheet(isPresented: $showActions) {
                if let song = player.current {
                    if let saved = library.song(song.id) { SongActionsSheet(song: saved) }
                    else { SaveSongSheet(song: song) }
                }
            }
            .fullScreenCover(isPresented: $showLyrics) { LyricsView() }
            .appFeedback()
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let song = player.current {
                    Section("再生中") { SongRow(song: song, trailing: player.playing ? "pause.fill" : "play.fill") { player.toggle() } more: { player.toggle() } }
                }
                Section("次に再生") {
                    if player.queue.upcoming.isEmpty { Text("次の曲はありません").foregroundStyle(Palette.secondary) }
                    ForEach(player.queue.upcoming, id: \.self) { id in
                        if let song = player.queuedSong(id) {
                            HStack(spacing: 12) {
                                SongArtwork(song: song, size: 44)
                                VStack(alignment: .leading, spacing: 5) { Text(song.title).font(.subheadline); Text(song.artist).font(.caption).foregroundStyle(Palette.secondary) }
                            }
                        }
                    }
                }
                Section { Text(player.queue.repeatMode.label).font(.caption).foregroundStyle(Palette.secondary) }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("再生キュー").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }
    }
}
