import SwiftUI

@main
struct UTubeMusicApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var player: PlayerStore
    @StateObject private var music: MusicService
    init() {
        IntroSilence.cleanup()
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: PlayerStore(library: library))
        _music = StateObject(wrappedValue: MusicService(library: library))
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library).environmentObject(player).environmentObject(music)
                .preferredColorScheme(.dark).tint(Palette.accent)
        }
    }
}
