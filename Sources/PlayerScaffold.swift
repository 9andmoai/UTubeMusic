import SwiftUI

// Exposed geometry also lets native regression tests measure the real viewport.
struct PlayerLayoutFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
struct PlayerScaffold<Content: View, Chrome: View>: View {
    var showsChrome = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let chrome: () -> Chrome
    var body: some View {
        VStack(spacing: 0) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { GeometryReader { geo in Color.clear.preference(key: PlayerLayoutFrames.self, value: ["content": geo.frame(in: .named("player-layout"))]) } }
            if showsChrome {
                chrome().fixedSize(horizontal: false, vertical: true)
                    .background { GeometryReader { geo in Color.clear.preference(key: PlayerLayoutFrames.self, value: ["chrome": geo.frame(in: .named("player-layout"))]) } }
            }
        }.coordinateSpace(name: "player-layout")
    }
}

struct SearchEditingPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
