import SwiftUI

@MainActor
final class SearchScreenState: ObservableObject {
    @Published var query = ""
    @Published var submitted = ""
    @Published var kind = "songs"
    @Published var generation = UUID()
    var lastToken: UUID?
    var requestedGeneration: UUID?
    let suggestionRequest: ([String: String]) async throws -> EngineResponse
    init(suggestionRequest: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) }, search: SongSearchStore? = nil) { self.suggestionRequest = suggestionRequest; self.search = search ?? SongSearchStore() }
    let search: SongSearchStore
    let catalog = CatalogStore()
}

struct SearchScreenView: View {
    let initialQuery: String
    var initialKind = "songs"
    let token: UUID
    let openDownloads: () -> Void
    @ObservedObject var state: SearchScreenState
    @FocusState private var searchFocused: Bool
    private var searchesFollows: Bool { state.kind == "podcast" || state.kind == "artist" }
    private var queryHint: String {
        switch state.kind {
        case "podcast": return "番組名・配信元名"
        case "artist": return "アーティスト名"
        default: return "曲名、アーティスト、YouTubeリンク"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !searchFocused {
            HStack {
                Text("検索").font(.largeTitle.bold())
                Spacer()
                IconButton(symbol: "arrow.down.circle", label: "保存の状況", action: openDownloads)
            }.padding(.horizontal, 20).padding(.vertical, 16)
            }
            HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField(queryHint, text: $state.query)
                    .focused($searchFocused)
                    .accessibilityIdentifier("main-search-field")
                    .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search).onSubmit(submit)
                if !state.query.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: "検索をクリア", color: Palette.secondary, size: 17) { state.query = ""; submit() }
                }
            }.padding(.leading, 15).padding(.trailing, 4).frame(minHeight: 52)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 13))
            if searchFocused { TextActionButton("完了") { searchFocused = false }.accessibilityIdentifier("finish-search-editing") }
            }.padding(.horizontal, 20).padding(.top, searchFocused ? 8 : 0)
            if !searchFocused {
            HStack {
                Text(searchesFollows ? queryHint : "曲名・アーティスト・プレイリストのリンク").font(.caption2).foregroundStyle(Palette.secondary)
                Spacer()
                TextActionButton("検索", action: submit)
            }.padding(.horizontal, 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("曲", value: "songs"); chip("プレイリスト", value: "playlists")
                        chip("アルバム", value: "albums"); chip("ポッドキャスト", value: "podcast")
                        chip("アーティスト", value: "artist")
                    }.padding(.horizontal, 20)
                }.onChange(of: state.kind, initial: true) { _, kind in proxy.scrollTo(kind, anchor: .center) }
            }.padding(.bottom, 12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 0).id("results-top")
                        if searchFocused {
                            if searchesFollows {
                                Text(queryHint + "を入力して検索してください").font(.caption).foregroundStyle(Palette.secondary)
                            } else {
                                SearchSuggestions(query: state.query, request: state.suggestionRequest) { state.query = $0; submit() }
                            }
                        } else if state.submitted.isEmpty && searchesFollows {
                            EmptyPanel(symbol: state.kind == "artist" ? "music.mic" : "dot.radiowaves.left.and.right",
                                       title: queryHint + "で探す", detail: "フォローした項目はライブラリから開けます。")
                        } else if state.submitted.isEmpty {
                            SectionTitle(title: "今の気分から探す", caption: "ジャンルを選んで、好きな音楽へ")
                            BrowseGenres { state.query = $0; state.kind = "songs"; submit() }
                            Text("公開プレイリスト・アルバムも検索できます。YouTube Musicの共有リンクは、上の検索欄に貼り付けてください。")
                                .font(.caption).foregroundStyle(Palette.secondary).lineSpacing(4)
                        } else if let item = CatalogItem.link(state.submitted) {
                            NavigationLink { RemoteCollectionView(item: item) } label: {
                                Label("プレイリスト・アルバムを開く", systemImage: "rectangle.stack.fill").font(.headline)
                                    .padding(20).frame(maxWidth: .infinity).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                            }
                        } else if searchesFollows {
                            FollowSearchResults(query: state.submitted, kind: state.kind).id(state.generation)
                        } else if state.kind == "songs" { SongSearchResults(search: state.search) }
                        else { CatalogSearchResults(store: state.catalog) }
                    }.padding(.horizontal, 20).padding(.bottom, 32)
                }.scrollDismissesKeyboard(searchFocused ? .never : .interactively).accessibilityIdentifier("search-scroll")
                    .onChange(of: state.generation) { _, _ in proxy.scrollTo("results-top", anchor: .top) }
                    .onChange(of: searchFocused) { _, focused in if focused { proxy.scrollTo("results-top", anchor: .top) } }
            }
        }.foregroundStyle(Palette.text)
            .preference(key: SearchEditingPreference.self, value: searchFocused)
            .onDisappear { searchFocused = false }
            .onChange(of: token, initial: true) { _, _ in
                if state.lastToken != token { state.lastToken = token; state.query = initialQuery; state.kind = initialKind; submit() }
            }
            .task(id: state.generation) {
                guard state.requestedGeneration != state.generation else { return }
                state.requestedGeneration = state.generation
                guard !searchesFollows, CatalogItem.link(state.submitted) == nil else { return }
                if state.kind == "songs" { await state.search.search(state.submitted) }
                else { await state.catalog.search(state.submitted, kind: state.kind) }
            }
    }
    private func chip(_ title: String, value: String) -> some View {
        Button { state.kind = value; submit() } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).frame(minHeight: 44)
                .background(state.kind == value ? Palette.text : Palette.raised, in: Capsule()).contentShape(Capsule())
                .foregroundStyle(state.kind == value ? Color.black : Palette.text)
        }.buttonStyle(.plain).id(value).accessibilityAddTraits(state.kind == value ? .isSelected : [])
    }
    private func submit() {
        searchFocused = false
        state.submitted = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        state.generation = UUID()
    }
}
