import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var music: MusicService
    @State private var tab = 0
    @State private var query = ""
    @State private var searchToken = UUID()
    @StateObject private var homeCatalog: CatalogStore
    @StateObject private var searchState: SearchScreenState
    @State private var searchEditing = false
    @State private var keyboardVisible = false
    @State private var showPlayer = false
    @State private var showDownloads = false
    @State private var showSettings = false
    init(initialTab: Int = 0, homeCatalog: CatalogStore? = nil, searchState: SearchScreenState? = nil) {
        _tab = State(initialValue: initialTab)
        _searchState = StateObject(wrappedValue: searchState ?? SearchScreenState())
        _homeCatalog = StateObject(wrappedValue: homeCatalog ?? CatalogStore())
    }

    var body: some View {
        PlayerScaffold(showsChrome: !searchEditing && !keyboardVisible) {
            // Reserve actual layout space for the player; never cover scroll content.
            NavigationStack {
                Group {
                    switch tab {
                    case 1: searchScreen
                    case 2: LibraryView()
                    default: homeScreen
                    }
                }
                .background(Palette.background)
                .toolbar(.hidden, for: .navigationBar)
            }.id(tab).frame(maxWidth: .infinity, maxHeight: .infinity)
        } chrome: { bottomBar }
        .background(Palette.background)
        .onPreferenceChange(SearchEditingPreference.self) { searchEditing = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showPlayer) { NowPlayingView() }
        .appFeedback()
        .onChange(of: tab) { _, _ in player.preview.stop() }
        .onChange(of: showPlayer) { _, value in if value { player.preview.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in player.preview.stop() }
        .onOpenURL { url in
            guard url.scheme == "utubemusic", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
            runSearch(value)
        }
    }
    private var homeScreen: some View {
        HomeScreenView(openSearch: runSearch, openDownloads: { showDownloads = true }, openSettings: { showSettings = true }, catalog: homeCatalog)
    }
    private var searchScreen: some View {
        SearchScreenView(initialQuery: query, token: searchToken, openDownloads: { showDownloads = true }, state: searchState)
    }
    private var bottomBar: some View {
        VStack(spacing: 0) {
            PreviewBanner(preview: player.preview)
            if let song = player.current {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { showPlayer = true } label: {
                            HStack(spacing: 10) {
                                SongArtwork(song: song, size: 42, radius: 6)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(player.preparingIntro ? "冒頭の無音を確認中…" : player.preparingVolume ? "音量を確認中…" : player.buffering ? "通信待ち…" : song.artist).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("再生画面を開く：\(song.title)")
                        IconButton(symbol: library.song(song.id)?.favorite == true ? "heart.fill" : "heart", label: "お気に入りを切り替え", color: library.song(song.id)?.favorite == true ? Palette.accent : Palette.text, size: 19) { library.toggleFavorite(song.id) }
                        IconButton(symbol: player.playing ? "pause.fill" : "play.fill", label: player.playing ? "一時停止" : "再生") { player.toggle() }
                    }.padding(.horizontal, 9).padding(.vertical, 7)
                    GeometryReader { geo in
                        Rectangle().fill(Palette.accent).frame(width: geo.size.width * min(1, max(0, player.elapsed / max(1, player.duration))))
                    }.frame(height: 2).background(.white.opacity(0.08))
                }.background(Palette.raised, in: RoundedRectangle(cornerRadius: 11)).clipShape(RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 8).padding(.bottom, 6)
            }
            HStack(spacing: 0) {
                tabButton(0, title: "ホーム", icon: "house", selected: "house.fill")
                tabButton(1, title: "検索", icon: "magnifyingglass", selected: "magnifyingglass")
                tabButton(2, title: "ライブラリ", icon: "square.stack", selected: "square.stack.fill")
            }.padding(.top, 6).padding(.bottom, 2)
        }.foregroundStyle(Palette.text).background(Palette.background).accessibilityIdentifier("bottom-player-bar")
    }
    private func tabButton(_ index: Int, title: String, icon: String, selected: String) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 5) {
                Image(systemName: tab == index ? selected : icon).font(.system(size: 22, weight: tab == index ? .semibold : .regular))
                Text(title).font(.system(size: 10, weight: .semibold))
            }.foregroundStyle(tab == index ? Palette.text : Palette.secondary).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
    }
    private func runSearch(_ value: String) { query = value; tab = 1; searchToken = UUID() }
}
