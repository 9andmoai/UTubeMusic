import SwiftUI
import UniformTypeIdentifiers

struct SaveSongSheet: View {
    let song: Song
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var music: MusicService
    @Environment(\.dismiss) private var dismiss
    @State private var download = false
    @State private var favorite = true
    @State private var playlistIDs: Set<UUID> = []
    @State private var create = false
    @State private var name = ""
    init(song: Song, initialFavorite: Bool = true, initialPlaylistIDs: Set<UUID> = []) {
        self.song = song
        _favorite = State(initialValue: initialFavorite)
        _playlistIDs = State(initialValue: initialPlaylistIDs)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        SongArtwork(song: song, size: 80)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(song.title).font(.headline).lineLimit(3)
                            Text(song.artist).font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("保存した曲は「ライブラリ」にまとまります。") .font(.subheadline)
                        Text("下で、お気に入りやプレイリストへの追加も選べます。")
                            .font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Toggle(isOn: $favorite) {
                        Label("お気に入りに追加", systemImage: favorite ? "heart.fill" : "heart")
                    }.tint(Palette.accent).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityIdentifier("save-favorite")
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "プレイリストにも追加", caption: "任意・複数選択できます")
                        VStack(spacing: 0) {
                            ForEach(library.playlists) { playlist in
                                Button {
                                    if playlistIDs.contains(playlist.id) { playlistIDs.remove(playlist.id) }
                                    else { playlistIDs.insert(playlist.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        PlaylistArtwork(name: playlist.name, size: 42)
                                        Text(playlist.name).font(.subheadline).multilineTextAlignment(.leading)
                                        Spacer(minLength: 4)
                                        Image(systemName: playlistIDs.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(playlistIDs.contains(playlist.id) ? Palette.accent : Palette.secondary)
                                    }.padding(12).frame(minHeight: 56).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityAddTraits(playlistIDs.contains(playlist.id) ? .isSelected : [])
                            }
                            Button { name = ""; create = true } label: {
                                Label("新しいプレイリストを作成", systemImage: "plus.circle")
                                    .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16)
                            }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                    Toggle("オフライン用にもダウンロード", isOn: $download).tint(Palette.accent)
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(download ? "このiPhoneに音声も保存" : "曲の情報だけ追加・再生時に通信").font(.subheadline.weight(.semibold))
                            Text("ダウンロードをオンにした曲はオフラインでも再生できます。").font(.caption).foregroundStyle(Palette.secondary).lineSpacing(4)
                        }
                    }
                    Text("保存する権利・許可のある曲を対象にしてください。")
                        .font(.caption2).foregroundStyle(Palette.secondary)
                }.padding(24)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("曲を追加").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        Text(favorite ? "お気に入り" + (playlistIDs.isEmpty ? "に追加" : " ＋ \(playlistIDs.count)個のプレイリストに追加") : playlistIDs.isEmpty ? "このiPhoneに保存" : "\(playlistIDs.count)個のプレイリストに追加")
                            .font(.caption).foregroundStyle(Palette.secondary)
                        PrimaryButton(title: download ? "ダウンロードして追加" : "曲を追加", symbol: "plus") {
                            if download { music.save(song, favorite: favorite, playlistIDs: playlistIDs); dismiss() }
                            else {
                                do { try library.addOnline(song, favorite: favorite, playlistIDs: playlistIDs); dismiss() }
                                catch { library.message = error.localizedDescription }
                            }
                        }.disabled(library.recoveryNeeded)
                    }.padding(20).background(Palette.background)
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .alert("新しいプレイリスト", isPresented: $create) {
                    TextField("名前", text: $name)
                    Button("キャンセル", role: .cancel) {}
                    Button("作成") { do { playlistIDs.insert(try library.createPlaylist(name)) } catch { library.message = error.localizedDescription } }
                }
        }.appFeedback().presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

struct BatchSaveSheet: View {
    let title: String
    let sourceID: String
    let songs: [Song]
    let onSaved: () -> Void
    @EnvironmentObject private var music: MusicService
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var download = false
    @State private var favorite = true
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PlaylistArtwork(name: title, size: 90)
                    Text(title).font(.title2.bold())
                    Text("\(songs.count)曲を「\(title)」プレイリストに保存します。") .font(.subheadline)
                    Toggle("全曲をオフライン用にもダウンロード", isOn: $download).tint(Palette.accent)
                    Toggle(isOn: $favorite) { Label("全曲をお気に入りにも追加", systemImage: "heart") }.tint(Palette.accent)
                    Text("お気に入りに入れず、プレイリストだけにまとめることもできます。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    Text(download ? "音声を1曲ずつ保存します。中止しても完了済みの曲は残ります。" : "音声はダウンロードせず、曲の情報だけを登録します。再生にはインターネット接続が必要です。")
                        .font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(5)
                    Text("保存が終わるまでアプリを開いてください。保存する権利・許可のある曲を対象にしてください。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }.padding(24)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("まとめて追加").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    PrimaryButton(title: download ? "\(songs.count)曲をダウンロード" : "\(songs.count)曲を追加", symbol: "plus") {
                        do { try music.saveCollection(songs, title: title, sourceID: sourceID, favorite: favorite, download: download); dismiss(); onSaved() }
                        catch { library.message = error.localizedDescription }
                    }.disabled(library.recoveryNeeded).padding(20).background(Palette.background)
                }
        }.appFeedback().presentationDragIndicator(.visible)
    }
}

struct SongActionsSheet: View {
    let song: Song
    @EnvironmentObject private var music: MusicService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var delete = false
    @State private var removeDownload = false
    @State private var editIntro = false
    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 14) {
                    SongArtwork(song: song, size: 64)
                    VStack(alignment: .leading, spacing: 6) { Text(song.title).font(.headline); Text(song.artist).font(.caption).foregroundStyle(Palette.secondary) }
                }.listRowBackground(Color.clear)
                Button { library.toggleFavorite(song.id) } label: {
                    Label(library.song(song.id)?.favorite == true ? "お気に入りから外す" : "お気に入りに追加", systemImage: library.song(song.id)?.favorite == true ? "heart.fill" : "heart")
                }
                if !library.isAvailable(song) {
                    Button { music.save(song, favorite: song.favorite, playlistIDs: []); dismiss() } label: { Label("オフライン用にダウンロード", systemImage: "arrow.down.circle") }
                }
                if library.canRemoveDownload(library.song(song.id) ?? song) {
                    Button { removeDownload = true } label: {
                        Label("ダウンロードだけ削除", systemImage: "arrow.down.circle")
                    }.accessibilityIdentifier("remove-download")
                }
                Button { player.start(library.songs, at: song); dismiss() } label: { Label("再生", systemImage: "play.fill") }.disabled(!library.isPlayable(song))
                Button { player.enqueue(song); dismiss() } label: { Label("再生キューに追加", systemImage: "text.line.first.and.arrowtriangle.forward") }.disabled(!library.isPlayable(song))
                Button { editIntro = true } label: {
                    Label("冒頭の無音をスキップ", systemImage: "forward.frame")
                }
                Section("プレイリストに追加") {
                    if library.playlists.isEmpty { Text("ライブラリの＋からプレイリストを作成できます。").font(.caption).foregroundStyle(Palette.secondary) }
                    ForEach(library.playlists) { playlist in
                        Button {
                            do { try library.add(song.id, to: playlist.id); dismiss() } catch { library.message = error.localizedDescription }
                        } label: { Label(playlist.name, systemImage: playlist.songIDs.contains(song.id) ? "checkmark.circle.fill" : "plus.circle") }
                    }
                }
                if let url = library.file(song.fileName), library.isAvailable(song) {
                    ShareLink(item: url) { Label("音声ファイルを共有", systemImage: "square.and.arrow.up") }
                }
                Section {
                    Button(role: .destructive) { delete = true } label: { Label("ライブラリから削除", systemImage: "trash") }
                }
            }.scrollContentBackground(.hidden).background(Palette.background).tint(Palette.text)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .sheet(isPresented: $editIntro) { IntroSkipSheet(song: library.song(song.id) ?? song) }
                .confirmationDialog("このiPhoneから曲を削除しますか？プレイリストからも外れます。検索から再保存できます。", isPresented: $delete, titleVisibility: .visible) {
                    Button("曲とファイルを削除", role: .destructive) {
                        do { try library.delete(song); player.remove(song.id); dismiss() } catch { library.message = error.localizedDescription }
                    }
                }
                .confirmationDialog("音声ファイルだけ削除してオンライン再生に切り替えますか？お気に入り・プレイリスト・曲順・ジャケットは残ります。再生中の場合は停止します。", isPresented: $removeDownload, titleVisibility: .visible) {
                    Button("ダウンロードだけ削除", role: .destructive) {
                        do {
                            try library.removeDownload(song.id)
                            player.releaseRemovedDownload(song.id)
                            library.message = "ダウンロードだけ削除しました。再生にはインターネット接続が必要です。"
                            dismiss()
                        } catch { library.message = error.localizedDescription }
                    }
                }
        }.appFeedback().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var music: MusicService
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                if music.jobs.isEmpty { EmptyPanel(symbol: "arrow.down.circle", title: "保存状況はここで確認", detail: "検索から曲を選んで保存できます。") }
                LazyVStack(spacing: 16) {
                    if !music.jobs.isEmpty {
                        HStack {
                            Text("\(music.jobs.filter(\.finished).count) / \(music.jobs.count)曲 保存完了").font(.subheadline.bold())
                            Spacer()
                            if music.jobs.contains(where: { !$0.finished && $0.error == nil }) {
                                Button("すべて中止") { music.cancelPending() }.font(.caption).frame(minHeight: 44)
                            }
                        }
                    }
                    ForEach(music.jobs) { job in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                SongArtwork(song: job.song, size: 48)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.song.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(job.error ?? job.phase).font(.caption).foregroundStyle(job.error == nil ? Palette.secondary : Palette.accent)
                                }
                                Spacer(minLength: 0)
                            }
                            if let _ = job.error {
                                HStack {
                                    Button("再試行") { music.retry(job.id) }.frame(minHeight: 44)
                                    Spacer()
                                    Button("閉じる") { music.dismiss(job.id) }.frame(minHeight: 44)
                                }.font(.subheadline.weight(.semibold))
                            } else if job.finished {
                                HStack {
                                    Button { player.start([job.song], at: job.song); dismiss() } label: { Label("再生", systemImage: "play.fill") }.frame(minHeight: 44)
                                    Spacer()
                                    IconButton(symbol: "xmark", label: "完了した保存を一覧から外す", size: 16) { music.dismiss(job.id) }
                                }
                            } else {
                                if job.fraction > 0 { ProgressView(value: job.fraction).tint(Palette.accent) }
                                else if job.phase != "保存待ち" { ProgressView().tint(Palette.accent) }
                                HStack {
                                    Text(job.fraction > 0 ? "\(Int(job.fraction * 100))%" : job.phase == "保存待ち" ? "順番に保存します" : "処理中").font(.caption).foregroundStyle(Palette.secondary)
                                    Spacer()
                                    Button("キャンセル") { music.cancel(job.id) }.font(.caption).frame(minHeight: 44)
                                }
                            }
                        }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                }.padding(20)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("保存の状況").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }.appFeedback().presentationDragIndicator(.visible)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var music: MusicService
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("保存した曲", value: "\(library.songs.count)曲")
                    LabeledContent("曲の容量", value: ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))
                    Button { importing = true } label: { Label("音声ファイルを読み込む", systemImage: "folder.badge.plus") }
                } header: { Text("このiPhoneのライブラリ") }
                Section("再生音量") {
                    Toggle("曲ごとの音量差を抑える", isOn: $player.normalizeVolume)
                    Text("大きい曲を−14 LUFSを目安に下げます。保存曲は初回再生前に端末内で測定し、オンライン曲は取得元の音量情報がある場合に調整します。小さい曲の増幅はしません。音源ファイルとiPhone本体の音量は変更しません。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Section("再生時間の修復") {
                    Button {
                        player.pause()
                        Task { await music.repairSavedSongs(); player.refreshAfterAudioRepair() }
                    } label: { Label("保存した曲の再生時間を修復", systemImage: "waveform.badge.magnifyingglass") }
                        .disabled(music.repairing || library.recoveryNeeded || music.jobs.contains { !$0.finished && $0.error == nil })
                    if let progress = music.repairProgress { ProgressView(progress) }
                    Text("音声ファイルを変更せず、アプリ内の再生時間を確認・修復します。再ダウンロードは不要です。お気に入り・プレイリストを保ったまま1曲ずつ処理します。完了までアプリを開いてください。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Section("バックアップ") {
                    Text("「ファイル」アプリ → このiPhone内 → UTube Music → UTubeMusic をフォルダーごとコピーすると、曲とプレイリストを保管できます。アプリを削除する前にバックアップしてください。")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                    Text("library.json が曲とプレイリストの一覧です。library.previous.json は直前の一覧です。読み込みエラー時はアプリを終了し、コピーを保管してから有効な一覧を library.json に戻してください。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Section("SideStoreでの期限更新") {
                    Text("Wi-Fiに接続 → LocalDevVPNをオン → SideStoreのMy AppsでUTube MusicとSideStoreを更新。通常7日の期限が切れる前に確認してください。更新に料金はかかりません。")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
                Section {
                    LabeledContent("バージョン", value: "0.3.4 開発版")
                    Text("個人用の音楽ライブラリ。曲の取得はYouTubeの仕様や制限により失敗する場合があります。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    Text("Python / yt-dlp / yt-dlp-ejs / certifi / yt-dlp-apple-webkit-jsi / ytmusicapi / requests を使用。ライセンスはアプリ内の同梱ファイル ThirdPartyNotices を参照。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    if let notice = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                        ShareLink("ライセンスを開く・共有", item: notice)
                    }
                }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("設定").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls):
                        Task {
                            var count = 0
                            var failures: [String] = []
                            for url in urls {
                                do { try await library.importAudio(url); count += 1 }
                                catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
                            }
                            dismiss()
                            library.message = "\(count)曲を読み込みました。" + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
                        }
                    case .failure(let error): library.message = error.localizedDescription
                    }
                }
        }.appFeedback()
    }
}
