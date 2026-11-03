import SwiftUI

struct BrowseGenres: View {
    let select: (String) -> Void
    private let genres = ["J-POP", "Chill", "ロック", "K-POP", "アニメ", "クラシック", "Jazz", "ピアノ"]
    private let symbols = ["sparkles", "moon.stars.fill", "guitars.fill", "star.fill", "play.rectangle.fill", "music.quarternote.3", "music.note", "pianokeys"]
    private let colors = [Color(red: 0.5, green: 0.2, blue: 0.28), Color(red: 0.22, green: 0.27, blue: 0.47), Color(red: 0.36, green: 0.23, blue: 0.18), Color(red: 0.37, green: 0.22, blue: 0.47)]
    var body: some View {
        // Eight browse cards fit an eager grid; their true full height is known
        // before scrolling, including when the player reduces the viewport.
        VStack(spacing: 12) {
            ForEach(0..<4) { row in
                HStack(spacing: 12) { card(row * 2); card(row * 2 + 1) }
            }
        }
    }
    private func card(_ index: Int) -> some View {
        Button { select(genres[index]) } label: {
            ZStack(alignment: .bottomTrailing) {
                Circle().stroke(.white.opacity(0.08), lineWidth: 22).frame(width: 100, height: 100).offset(x: 22, y: 40)
                VStack(alignment: .leading, spacing: 20) {
                    Text(genres[index]).font(.headline)
                    Image(systemName: symbols[index]).font(.system(size: 24, weight: .light)).frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(18)
            }.frame(maxWidth: .infinity, minHeight: 120).foregroundStyle(Palette.text)
                .background(colors[index % colors.count], in: RoundedRectangle(cornerRadius: 14)).clipShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityIdentifier("genre-\(index)")
            .background { GeometryReader { geo in Color.clear.preference(key: PlayerLayoutFrames.self, value: ["genre-\(index)": geo.frame(in: .named("player-layout"))]) } }
    }
}

struct CatalogArtwork: View {
    let item: CatalogItem
    var size: CGFloat = 156
    var body: some View {
        Group {
            if let value = item.thumbnail, let url = URL(string: value) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }.frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: item.kind == "album" ? 5 : 12)).accessibilityHidden(true)
    }
    private var placeholder: some View { PlaylistArtwork(name: item.title, size: size) }
}
struct CatalogShelf: View {
    let title: String
    let items: [CatalogItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink { RemoteCollectionView(item: item) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CatalogArtwork(item: item)
                                Text(item.title).font(.subheadline.bold()).lineLimit(2)
                                Text(item.kindLabel + " · " + item.subtitle).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                            }.frame(width: 156, alignment: .leading).foregroundStyle(Palette.text)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct SearchMoreButton: View {
    let loading: Bool
    let error: String?
    let action: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            if let error { Text(error).font(.caption).foregroundStyle(Palette.secondary).multilineTextAlignment(.center) }
            Button(action: action) {
                HStack(spacing: 10) {
                    if loading { ProgressView().tint(Palette.accent) }
                    else { Image(systemName: error == nil ? "plus.circle" : "arrow.clockwise") }
                    Text(loading ? "読み込み中…" : error == nil ? "さらに表示" : "もう一度読み込む").font(.subheadline.bold())
                }.frame(maxWidth: .infinity, minHeight: 52).background(Palette.surface, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain).disabled(loading).accessibilityIdentifier("load-more")
        }.padding(.vertical, 16)
    }
}
struct SongSearchResults: View {
    @ObservedObject var search: SongSearchStore
    var destination: SongAddDestination? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @State private var save: Song?
    @State private var menu: Song?
    var body: some View {
        LazyVStack(spacing: 4) {
            if search.searching { ProgressView("曲を探しています…").tint(Palette.accent).frame(maxWidth: .infinity).padding(.vertical, 50) }
            else if let error = search.error { EmptyPanel(symbol: "wifi.exclamationmark", title: "曲を読み込めませんでした", detail: error + "\n上の検索ボタンから再試行できます。") }
            else {
                ForEach(search.results) { song in
                    let existing = library.song(song.id)
                    let available = existing.map(library.isPlayable) ?? false
                    if let destination, let existing, available {
                        DestinationSongRow(song: existing, destination: destination)
                    } else {
                    SongRow(song: song, subtitle: song.artist + (song.duration > 0 ? " · " + song.timeLabel : ""), trailing: available ? "ellipsis" : "plus.circle", allowsPreview: true) {
                        if let existing, available { player.start([existing], at: existing) } else { save = song }
                    } more: { if let existing, available { menu = existing } else { save = song } }
                    }
                }
                if search.hasMore {
                    SearchMoreButton(loading: search.loadingMore, error: search.moreError) { Task { await search.loadMore() } }
                } else if search.results.isEmpty {
                    EmptyPanel(symbol: "music.magnifyingglass", title: "曲が見つかりませんでした", detail: "別の曲名やアーティストで探してみてください。")
                } else { Text("ここまで\(search.results.count)曲を表示").font(.caption).foregroundStyle(Palette.secondary).padding(.vertical, 22) }
            }
        }.sheet(item: $save) { SaveSongSheet(song: $0, initialPlaylistIDs: destination?.initialPlaylistIDs ?? []) }.sheet(item: $menu) { SongActionsSheet(song: $0) }
            .onDisappear { player.preview.stop() }
            .onChange(of: save?.id) { _, value in if value != nil { player.preview.stop() } }
    }
}
struct CatalogSearchResults: View {
    @ObservedObject var store: CatalogStore
    var body: some View {
        LazyVStack(spacing: 16) {
            if store.loading { ProgressView("探しています…").tint(Palette.accent).padding(.vertical, 50) }
            else if let error = store.error { EmptyPanel(symbol: "wifi.exclamationmark", title: "読み込めませんでした", detail: error + "\n上の検索ボタンから再試行できます。") }
            else {
                ForEach(store.items) { item in
                    NavigationLink { RemoteCollectionView(item: item) } label: {
                        HStack(spacing: 14) {
                            CatalogArtwork(item: item, size: 72)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.subheadline.bold()).lineLimit(2)
                                Text(item.kindLabel + " · " + item.subtitle).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
                        }.foregroundStyle(Palette.text).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if store.hasMore { SearchMoreButton(loading: store.loadingMore, error: store.moreError) { Task { await store.loadMore() } } }
                else if store.items.isEmpty { EmptyPanel(symbol: "rectangle.stack", title: "見つかりませんでした", detail: "別のアーティスト名やタイトルを試してください。") }
                else { Text("ここまで\(store.items.count)件を表示").font(.caption).foregroundStyle(Palette.secondary).padding(.vertical, 22) }
            }
        }.frame(maxWidth: .infinity)
    }
}

@MainActor
struct RemoteCollectionView: View {
    let item: CatalogItem
    @StateObject private var store: CatalogStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var music: MusicService
    @EnvironmentObject private var player: PlayerStore
    @State private var save: Song?
    @State private var menu: Song?
    @State private var confirm = false
    @State private var showDownloads = false
    @State private var batchQueued = false
    init(item: CatalogItem, store: CatalogStore? = nil) {
        self.item = item
        _store = StateObject(wrappedValue: store ?? CatalogStore())
    }
    private var displayed: CatalogItem { store.collection ?? item }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CatalogArtwork(item: displayed, size: 220).frame(maxWidth: .infinity).padding(.top, 16)
                Text(displayed.title).font(.largeTitle.bold())
                Text(displayed.kindLabel + (displayed.subtitle.isEmpty ? "" : " · " + displayed.subtitle)).font(.subheadline).foregroundStyle(Palette.secondary)
                if store.loading { ProgressView("収録曲を読み込み中…").tint(Palette.accent).frame(maxWidth: .infinity).padding(30) }
                else if let error = store.error {
                    EmptyPanel(symbol: "wifi.exclamationmark", title: "収録曲を取得できませんでした", detail: error)
                    PrimaryButton(title: "もう一度読み込む") { Task { await store.open(item) } }
                } else {
                    Text("\(store.songs.count)曲 · " + Song.clock(store.songs.reduce(0) { $0 + $1.duration })).font(.caption).foregroundStyle(Palette.secondary)
                    PrimaryButton(title: "まとめて追加", symbol: "arrow.down.circle") { confirm = true }.disabled(store.songs.isEmpty || library.recoveryNeeded)
                    Text("曲の情報だけ追加するか、音声もダウンロードするか選べます。")
                        .font(.caption).foregroundStyle(Palette.secondary).lineSpacing(3)
                    if store.unavailable > 0 { Text("非公開・再生不可・重複などの\(store.unavailable)件は一覧から除外しています。") .font(.caption).foregroundStyle(Palette.secondary) }
                    ForEach(store.songs) { song in
                        let existing = library.song(song.id)
                        let available = existing.map(library.isPlayable) ?? false
                        SongRow(song: song, trailing: available ? "ellipsis" : "plus.circle", allowsPreview: true) {
                            if let existing, available { player.start(store.songs.compactMap { library.song($0.id) }.filter(library.isPlayable), at: existing) }
                            else { save = song }
                        } more: { if let existing, available { menu = existing } else { save = song } }
                    }
                    if store.songs.isEmpty { EmptyPanel(symbol: "music.note", title: "保存できる曲がありません", detail: "公開状態や地域によって収録曲を取得できない場合があります。") }
                }
            }.padding(20).padding(.bottom, 16)
        }.background(Palette.background).foregroundStyle(Palette.text)
            .toolbar(.visible, for: .navigationBar).toolbarBackground(Palette.background, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { IconButton(symbol: "arrow.down.circle", label: "保存の状況") { showDownloads = true } } }
            .task { if !store.loaded { await store.open(item) } }
            .onDisappear { player.preview.stop() }
            .onChange(of: save?.id) { _, value in if value != nil { player.preview.stop() } }
            .sheet(item: $save) { SaveSongSheet(song: $0) }.sheet(item: $menu) { SongActionsSheet(song: $0) }
            .sheet(isPresented: $showDownloads) { DownloadsView() }
            .sheet(isPresented: $confirm, onDismiss: {
                if batchQueued { batchQueued = false; showDownloads = true }
            }) {
                BatchSaveSheet(title: displayed.title, sourceID: displayed.id, songs: store.songs) {
                    batchQueued = music.jobs.contains { !$0.finished && $0.error == nil }
                }
            }
    }
}
