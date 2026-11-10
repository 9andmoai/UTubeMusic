import SwiftUI

enum SongAddDestination: Equatable {
    case library, favorites, playlist(UUID)

    var initialPlaylistIDs: Set<UUID> {
        if case .playlist(let id) = self { return [id] }
        return []
    }
    @MainActor func name(in library: LibraryStore) -> String {
        switch self {
        case .library: return "保存した曲"
        case .favorites: return "お気に入りの曲"
        case .playlist(let id): return library.playlists.first { $0.id == id }?.name ?? "削除されたプレイリスト"
        }
    }
    @MainActor func contains(_ song: Song, in library: LibraryStore) -> Bool {
        switch self {
        case .library: return library.song(song.id) != nil
        case .favorites: return library.song(song.id)?.favorite == true
        case .playlist(let id): return library.playlists.first { $0.id == id }?.songIDs.contains(song.id) == true
        }
    }
    @MainActor func add(_ song: Song, to library: LibraryStore) throws {
        guard var existing = library.song(song.id), library.isPlayable(existing) else {
            throw AppFailure("曲を保存してから追加してください。")
        }
        switch self {
        case .library: break
        case .favorites:
            existing.favorite = true
            try library.save(existing, playlistIDs: [])
        case .playlist(let id):
            guard library.playlists.contains(where: { $0.id == id }) else { throw AppFailure("プレイリストが削除されています。戻って追加先を選び直してください。") }
            try library.add(existing.id, to: id)
        }
    }
}

struct AddSongsLink: View {
    let destination: SongAddDestination
    var body: some View {
        NavigationLink { AddSongsView(destination: destination) } label: {
            Label("曲を追加", systemImage: "plus.circle")
                .font(.subheadline.bold()).foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.raised, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("add-songs-link")
    }
}

@MainActor
struct AddSongsView: View {
    let destination: SongAddDestination
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @State private var mode: Int
    @State private var query = ""
    @State private var submitted = ""
    @State private var generation = UUID()
    @StateObject private var search = SongSearchStore()
    @FocusState private var focused: Bool
    init(destination: SongAddDestination, initialMode: Int = 0) {
        self.destination = destination
        _mode = State(initialValue: initialMode)
    }
    private var savedSongs: [Song] {
        let available = library.songs.filter(library.isPlayable)
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? available : available.filter { $0.title.localizedCaseInsensitiveContains(value) || $0.artist.localizedCaseInsensitiveContains(value) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if !focused {
                Text("追加先：" + destination.name(in: library)).font(.subheadline.bold()).lineLimit(2)
                if destination != .library {
                    Picker("曲の探し方", selection: $mode) {
                        Text("新しい曲を検索").tag(0)
                        Text("保存した曲から").tag(1)
                    }.pickerStyle(.segmented).accessibilityIdentifier("add-songs-mode")
                }
                }
                HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField(mode == 0 ? "曲名、アーティスト、曲のリンク" : "保存した曲を絞り込む", text: $query)
                        .focused($focused).font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .submitLabel(.search).onSubmit(submit)
                    if !query.isEmpty {
                        IconButton(symbol: "xmark.circle.fill", label: "検索をクリア", color: Palette.secondary, size: 17) { query = ""; submit() }
                    }
                }.padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 52)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 13))
                if focused { TextActionButton("完了") { focused = false } }
                }
                if mode == 0 && !focused {
                    HStack {
                        Text("見つけた曲を、この追加先に保存").font(.caption).foregroundStyle(Palette.secondary)
                        Spacer()
                        TextActionButton("検索", action: submit)
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 0).id("add-top")
                        if mode == 0 && focused { SearchSuggestions(query: query) { query = $0; submit() } }
                        else if mode == 1 {
                            if savedSongs.isEmpty {
                                EmptyPanel(symbol: "music.note.list", title: "曲がありません", detail: "「新しい曲を検索」から曲を探して保存できます。")
                            }
                            ForEach(savedSongs) { song in DestinationSongRow(song: song, destination: destination) }
                        } else if submitted.isEmpty {
                            SectionTitle(title: "追加したい曲を見つけよう", caption: "曲を選ぶと、保存先を確認できます")
                            BrowseGenres { query = $0; submit() }
                        } else {
                            SongSearchResults(search: search, destination: destination)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 32)
                }.scrollDismissesKeyboard(focused ? .never : .interactively)
                    .onChange(of: generation) { _, _ in proxy.scrollTo("add-top", anchor: .top) }
                    .onChange(of: focused) { _, value in if value { proxy.scrollTo("add-top", anchor: .top) } }
                    .onChange(of: mode) { _, _ in focused = false; proxy.scrollTo("add-top", anchor: .top) }
            }
        }.background(Palette.background).foregroundStyle(Palette.text)
            .preference(key: SearchEditingPreference.self, value: focused)
            .navigationTitle("曲を追加").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).toolbarBackground(Palette.background, for: .navigationBar)
            .task(id: generation) { await search.search(submitted) }
            .appFeedback()
            .onDisappear { player.preview.stop() }
            .onChange(of: mode) { _, _ in player.preview.stop() }
    }
    private func submit() {
        focused = false
        if mode == 0 { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines); generation = UUID() }
    }
}

struct DestinationSongRow: View {
    let song: Song
    let destination: SongAddDestination
    @EnvironmentObject private var library: LibraryStore
    private var added: Bool { destination.contains(song, in: library) }
    var body: some View {
        SongRow(song: song, trailing: added ? "checkmark.circle.fill" : "plus.circle",
                trailingLabel: added ? "\(song.title)は追加済み" : "\(song.title)を追加", allowsPreview: true) { add() } more: { add() }
    }
    private func add() {
        guard !added else { return }
        do { try destination.add(song, to: library) }
        catch { library.message = error.localizedDescription }
    }
}
