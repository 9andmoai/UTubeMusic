import SwiftUI

struct FollowSource: Identifiable, Codable, Equatable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let thumbnail: String?

    var label: String {
        switch kind {
        case "artist": return "アーティスト"
        case "publisher": return "配信元"
        default: return "ポッドキャスト"
        }
    }
}

struct FollowSearchResults: View {
    let query: String
    let kind: String
    @State private var results: [FollowSource] = []
    @State private var loading = true
    @State private var error: String?
    @State private var retry = UUID()

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if loading {
                ProgressView("検索中…").tint(Palette.accent)
            } else if let error {
                EmptyPanel(symbol: "wifi.exclamationmark", title: "検索できませんでした", detail: error)
                TextActionButton("再試行") { retry = UUID() }
            } else if results.isEmpty {
                EmptyPanel(symbol: "magnifyingglass", title: "一致する項目がありません",
                           detail: "別の名前で検索してください。")
            } else {
                ForEach(results) { FollowLink(source: $0, size: 62) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: retry) {
                loading = true; error = nil
                defer { if !Task.isCancelled { loading = false } }
                do {
                    let response = try await PythonService.shared.request(["op": "follow_search", "kind": kind, "query": query])
                    try Task.checkCancellation()
                    results = response.follows ?? []
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
    }
}

struct FollowLink: View {
    let source: FollowSource
    var size: CGFloat = 52

    var body: some View {
        NavigationLink { FollowDetailView(source: source) } label: {
            HStack(spacing: 12) {
                PlaylistArtwork(name: source.title, size: size, cover: source.thumbnail)
                    .clipShape(RoundedRectangle(cornerRadius: source.kind == "artist" ? size / 2 : 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title).font(.headline)
                    Text(source.subtitle.isEmpty ? source.label : source.subtitle).font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
            }.frame(minHeight: 56).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct FollowDetailView: View {
    let source: FollowSource
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @State private var feed: EngineResponse?
    @State private var loading = false
    @State private var error: String?
    @State private var order = EpisodeOrder.newest
    @State private var watchEpisode: Song?

    private enum EpisodeOrder: String, CaseIterable, Identifiable {
        case newest = "新しい順"
        case oldest = "古い順"
        var id: Self { self }
    }

    private var displayed: FollowSource { feed?.follow ?? source }
    private var followed: Bool { library.follows.contains { $0.id == source.id } }
    private var tracks: [Song] {
        let songs = (feed?.songs ?? []).map(\.song)
        return order == .newest ? songs : Array(songs.reversed())
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PlaylistArtwork(name: displayed.title, size: 170, cover: displayed.thumbnail)
                    .frame(maxWidth: .infinity)
                Text(displayed.title).font(.title.bold())
                if let publisher = feed?.publisher { FollowLink(source: publisher) }
                HStack {
                    Text(displayed.label).foregroundStyle(Palette.secondary)
                    Spacer()
                    TextActionButton(followed ? "フォロー解除" : "フォローする") {
                        do { try library.toggleFollow(displayed) }
                        catch { library.message = error.localizedDescription }
                    }
                }
                if loading { ProgressView("更新中…").tint(Palette.accent) }
                if let error {
                    Text(error).foregroundStyle(Palette.secondary)
                    TextActionButton("再試行") { Task { await refresh() } }
                }
                if let shows = feed?.follows, !shows.isEmpty {
                    Text("番組").font(.headline)
                    ForEach(shows) { FollowLink(source: $0) }
                }
                if let releases = feed?.items, !releases.isEmpty {
                    CatalogShelf(title: "公開リリース", items: releases)
                }
                if let first = tracks.first {
                    Picker("再生順", selection: $order) {
                        ForEach(EpisodeOrder.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    PrimaryButton(title: "上から連続再生", symbol: "play.fill") { play(first) }
                    ForEach(tracks) { episode in
                        SongRow(song: episode, subtitle: episode.timeLabel, trailing: "applewatch",
                                trailingLabel: "Apple Watchに送る", actionLabel: "\(episode.title)を再生") {
                            play(episode)
                        } more: { watchEpisode = episode }
                    }
                }
                if let feed, (feed.songs ?? []).isEmpty && (feed.items ?? []).isEmpty && (feed.follows ?? []).isEmpty {
                    Text("公開コンテンツがありません").foregroundStyle(Palette.secondary)
                }
            }.padding(20)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { IconButton(symbol: "arrow.clockwise", label: "更新") { Task { await refresh() } }.disabled(loading) } }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $watchEpisode) { WatchEpisodeSheet(episode: $0) }
        .appFeedback()
    }

    private func play(_ episode: Song) {
        player.start(tracks, at: episode, source: .podcast(displayed.title))
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let response = try await PythonService.shared.request(["op": "follow_feed", "id": source.id, "kind": source.kind])
            try Task.checkCancellation()
            feed = response
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
