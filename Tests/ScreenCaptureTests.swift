import XCTest
import SwiftUI
import AVFoundation
@testable import UTubeMusic

@MainActor
final class ScreenCaptureTests: XCTestCase {
    func testKeyboardHidesChromeExpandsSuggestionsAndRestoresPlaybackControls() async throws {
        let (library, player, music, song) = try playableLibrary()
        defer { player.pause() }
        let response = try JSONDecoder().decode(EngineResponse.self, from: Data(#"{"ok":true,"suggestions":["安室奈美恵","安室奈美恵 Love Story","安室奈美恵 CAN YOU CELEBRATE?","安室奈美恵 Hero"]}"#.utf8))
        let empty = try JSONDecoder().decode(EngineResponse.self, from: Data(#"{"ok":true,"songs":[]}"#.utf8))
        let state = SearchScreenState(suggestionRequest: { _ in response }, search: SongSearchStore { _ in empty })
        var frames: [String: CGRect] = [:]
        let view = RootView(initialTab: 1, searchState: state)
            .environmentObject(library).environmentObject(player).environmentObject(music)
            .onPreferenceChange(PlayerLayoutFrames.self) { frames = $0 }
        try await render(view, name: "native-search-restored", prepare: { window in
            XCTAssertGreaterThan(frames["chrome"]?.height ?? 0, 100)
            let ready = Date().addingTimeInterval(4)
            while !player.playing && Date() < ready { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertTrue(player.playing)
            func fields(_ view: UIView) -> [UITextField] {
                (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let field = try XCTUnwrap(fields(window).first)
            XCTAssertTrue(field.becomeFirstResponder())
            state.query = "安室"
            let deadline = Date().addingTimeInterval(4)
            while frames["suggestion-安室奈美恵"] == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            window.layoutIfNeeded()
            XCTAssertNil(frames["chrome"], "Typing must remove both navigation and mini player from layout")
            let row = try XCTUnwrap(frames["suggestion-安室奈美恵"])
            let third = try XCTUnwrap(frames["suggestion-安室奈美恵 CAN YOU CELEBRATE?"])
            let content = try XCTUnwrap(frames["content"])
            XCTAssertGreaterThanOrEqual(row.width, 340); XCTAssertGreaterThanOrEqual(row.height, 55)
            XCTAssertLessThan(third.maxY, content.maxY, "At least the first three full-width choices must be visible")
            XCTAssertEqual(player.current?.id, song.id); XCTAssertTrue(player.playing, "Hiding controls must not stop music")
            self.capture(window, name: "native-search-keyboard", keyboard: true)
            window.endEditing(true)
            let restore = Date().addingTimeInterval(3)
            while frames["chrome"] == nil && Date() < restore { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertGreaterThan(frames["chrome"]?.height ?? 0, 100)
            XCTAssertEqual(state.query, "安室"); XCTAssertEqual(player.current?.id, song.id)
        })
    }
    func testCaptureIntroSkip() async throws {
        let (library, player, music, song) = try playableLibrary()
        defer { player.pause() }
        try library.setIntroSkip(song.id, seconds: 1)
        try await render(IntroSkipSheet(song: library.song(song.id)!).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-intro-skip")
    }
    func testCaptureLoudnessSettings() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(SettingsView().environmentObject(library).environmentObject(player).environmentObject(music), name: "native-settings")
    }
    func testCaptureBulkDownloadSelection() async throws {
        let (library, player, music, old) = try playableLibrary()
        defer { player.pause() }
        let ids = ["00000000001", "00000000002", "00000000003"]
        for (index, id) in ids.enumerated() {
            try library.save(Song(id: id, title: "お気に入りの曲 \(index + 1)", artist: "画面確認用", duration: old.duration, fileName: old.fileName, favorite: true), playlistIDs: [])
        }
        try await render(NavigationStack { LibraryView(initialFilter: 3, initialSelection: true, initialSelectedIDs: Set(ids.prefix(2))) }
            .environmentObject(library).environmentObject(player).environmentObject(music), name: "native-download-selection")
    }
    func testCaptureDownloadedLibrary() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(NavigationStack { LibraryView(initialFilter: 3) }.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-download-library")
    }
    func testCaptureDownloadRemovalMenu() async throws {
        let (library, player, music, old) = try playableLibrary()
        defer { player.pause() }
        let song = Song(id: "00000000001", title: old.title, artist: old.artist, duration: old.duration,
                        fileName: old.fileName, favorite: true)
        try library.save(song, playlistIDs: [])
        try await render(SongActionsSheet(song: song).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-download-menu")
    }
    private func render<V: View>(_ view: V, name: String, scrollToBottom: Bool = false, prepare: ((UIWindow) async throws -> Void)? = nil, inspect: ((UIWindow) -> Void)? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844) // iPhone 14 viewport.
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(.dark).tint(Palette.accent))
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        window.layoutIfNeeded()
        try await prepare?(window)
        window.layoutIfNeeded()
        if scrollToBottom {
            func scrolls(_ view: UIView) -> [UIScrollView] {
                let own = (view as? UIScrollView).map { [$0] } ?? []
                return own + view.subviews.flatMap(scrolls)
            }
            let candidates = scrolls(window).filter { $0.isScrollEnabled && !$0.isHidden && $0.contentSize.height > $0.bounds.height + 20 && $0.contentSize.width <= $0.bounds.width + 2 }
            for scroll in candidates { print("Scroll candidate:", type(of: scroll), scroll.accessibilityIdentifier ?? "nil", scroll.bounds, scroll.contentSize) }
            let scroll = try XCTUnwrap(candidates.last(where: { $0.accessibilityIdentifier == "search-scroll" }) ?? candidates.last)
            for _ in 0..<3 {
                window.layoutIfNeeded()
                let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            window.layoutIfNeeded()
            print("Scrolled to:", scroll.contentOffset, "size:", scroll.contentSize, "viewport:", scroll.bounds.size)
            XCTAssertGreaterThan(scroll.contentOffset.y, 0, "The actual search scroll view must move")
        }
        inspect?(window)
        capture(window, name: name)
    }
    private func capture(_ window: UIWindow, name: String, keyboard: Bool = false) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            if keyboard, let scene = window.windowScene {
                for overlay in scene.windows.filter({ $0 !== window && !$0.isHidden && $0.windowLevel > window.windowLevel }).sorted(by: { $0.windowLevel < $1.windowLevel }) {
                    context.cgContext.saveGState()
                    let origin = overlay.convert(CGPoint.zero, to: window)
                    context.cgContext.translateBy(x: origin.x, y: origin.y)
                    overlay.drawHierarchy(in: overlay.bounds, afterScreenUpdates: true)
                    context.cgContext.restoreGState()
                }
            }
        }
        XCTAssertGreaterThan(image.size.width, 300)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCaptureNativeHome() async throws {
        let library = LibraryStore(root: try root())
        let player = PlayerStore(library: library, introProbe: { _, _ in nil })
        let music = MusicService(library: library)
        let catalog = CatalogStore { _ in
            let data = Data(#"{"ok":true,"sections":[{"id":"public","title":"見つけるプレイリスト","items":[{"id":"PLpreview01","kind":"playlist","title":"Chill & Relax","subtitle":"画面確認用","thumbnail":null},{"id":"MPREb_preview","kind":"album","title":"Piano Collection","subtitle":"画面確認用","thumbnail":null}]}]}"#.utf8)
            return try JSONDecoder().decode(EngineResponse.self, from: data)
        }
        try await render(RootView(homeCatalog: catalog).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-home")
    }
    func testCaptureNativePlayer() async throws {
        let library = LibraryStore(root: try root())
        let url = library.root.appendingPathComponent("preview-silence.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050))
            buffer.frameLength = 22050
            if let samples = buffer.floatChannelData?[0] { for i in 0..<22050 { samples[i] = 0 } }
            for _ in 0..<60 { try file.write(from: buffer) }
        }
        let song = Song(id: "local-preview", title: "UTube Music 再生テスト", artist: "画面確認用の無音データ", duration: 60, fileName: url.lastPathComponent, favorite: true)
        try library.save(song, playlistID: nil)
        let player = PlayerStore(library: library, introProbe: { _, _ in nil })
        player.start([song], at: song)
        defer { player.pause() }
        try await render(NowPlayingView().environmentObject(library).environmentObject(player), name: "native-player")
    }
    private func playableLibrary() throws -> (LibraryStore, PlayerStore, MusicService, Song) {
        let library = LibraryStore(root: try root())
        let url = library.root.appendingPathComponent("layout-silence.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050))
            buffer.frameLength = 22050
            if let samples = buffer.floatChannelData?[0] { for i in 0..<22050 { samples[i] = 0 } }
            for _ in 0..<60 { try file.write(from: buffer) }
        }
        let song = Song(id: "local-layout", title: "お気に入りのピアノ", artist: "画面確認用の無音データ", duration: 60, fileName: url.lastPathComponent, favorite: true)
        let list = try library.createPlaylist("夜に聴きたい曲")
        try library.save(song, playlistID: list)
        let player = PlayerStore(library: library, introProbe: { _, _ in nil })
        player.start([song], at: song)
        return (library, player, MusicService(library: library), song)
    }
    func testCaptureSearchDuringPlaybackAndLastGenreAbovePlayer() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        var frames: [String: CGRect] = [:]
        let view = RootView(initialTab: 1).environmentObject(library).environmentObject(player).environmentObject(music)
            .onPreferenceChange(PlayerLayoutFrames.self) { frames = $0 }
        try await render(view, name: "native-search-bottom", scrollToBottom: true) { _ in
            guard let content = frames["content"], let chrome = frames["chrome"], let piano = frames["genre-7"] else {
                XCTFail("Missing measured layout regions: \(frames.keys)"); return
            }
            XCTAssertLessThanOrEqual(content.maxY, chrome.minY + 1)
            XCTAssertGreaterThan(chrome.height, 100, "Mini player and navigation must reserve their full height")
            XCTAssertLessThanOrEqual(piano.maxY, chrome.minY - 12, "Piano button must be visible without overscrolling")
            XCTAssertGreaterThan(piano.minY, content.minY)
        }
    }
    func testCaptureSearchPlaying() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(RootView(initialTab: 1).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-search-playing")
    }
    func testCaptureSaveChoices() async throws {
        let (library, player, music, song) = try playableLibrary()
        defer { player.pause() }
        try library.createPlaylist("通学のおとも")
        try await render(SaveSongSheet(song: song).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-save")
    }
    func testCaptureLibraryPlaying() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(RootView(initialTab: 2).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-library")
    }
    func testCaptureRemoteAlbum() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        let data = Data(#"{"ok":true,"collection":{"id":"MPREb_preview","kind":"album","title":"Piano Collection","subtitle":"画面確認用","thumbnail":null},"songs":[{"id":"00000000001","title":"Morning Light","artist":"画面確認用","duration":180},{"id":"00000000002","title":"Quiet Room","artist":"画面確認用","duration":210},{"id":"00000000003","title":"After Hours","artist":"画面確認用","duration":190}]}"#.utf8)
        let response = try JSONDecoder().decode(EngineResponse.self, from: data)
        let item = try XCTUnwrap(response.collection)
        let store = CatalogStore { _ in response }
        await store.open(item)
        try await render(NavigationStack { RemoteCollectionView(item: item, store: store) }.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-album")
    }
    func testCaptureBatchSave() async throws {
        let (library, player, music, song) = try playableLibrary()
        defer { player.pause() }
        try await render(BatchSaveSheet(title: "Piano Collection", sourceID: "MPREb_preview", songs: [song], onSaved: {}).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-batch-save")
    }
    func testCaptureFavoritesAddButton() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(NavigationStack { CollectionView(favorites: true) }.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-favorites-add")
    }
    func testCapturePlaylistAddButton() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        let playlist = try XCTUnwrap(library.playlists.first)
        try await render(NavigationStack { PlaylistDetailView(playlistID: playlist.id) }.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-playlist-add")
    }
    func testCaptureAddSearchWithDestination() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        let playlist = try XCTUnwrap(library.playlists.first)
        try await render(NavigationStack { AddSongsView(destination: .playlist(playlist.id)) }.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-add-search")
    }
    func testCaptureAddSavedSongs() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        let target = try library.createPlaylist("通学のおとも")
        try await render(NavigationStack { AddSongsView(destination: .playlist(target), initialMode: 1) }.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-add-saved")
    }
    func testCapturePreviewControlsAndBanner() async throws {
        let (library, player, music, song) = try playableLibrary()
        defer { player.pause() }
        player.togglePreview(song)
        let view = PlayerScaffold {
            VStack(alignment: .leading, spacing: 18) {
                Text("曲を試し聞き").font(.largeTitle.bold())
                Text("保存する前に、再生ボタンで確認できます。")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
                SongRow(song: song, trailing: "arrow.down.circle", allowsPreview: true, action: {}, more: {})
                Spacer()
            }.padding(20).background(Palette.background)
        } chrome: { PreviewBanner(preview: player.preview) }
        try await render(view.environmentObject(library).environmentObject(player).environmentObject(music), name: "native-preview")
        XCTAssertNotNil(player.preview.song)
        XCTAssertFalse(player.playing)
    }
}
