import SwiftUI

struct PreviewButton: View {
    let song: Song
    @EnvironmentObject private var player: PlayerStore
    var body: some View { PreviewControl(song: song, preview: player.preview) { player.togglePreview(song) } }
}

private struct PreviewControl: View {
    let song: Song
    @ObservedObject var preview: PreviewController
    let action: () -> Void
    private var active: Bool { preview.song?.id == song.id }
    var body: some View {
        Button(action: action) {
            Group {
                if active && preview.loading { ProgressView().tint(Palette.accent) }
                else { Image(systemName: active ? "stop.circle.fill" : "play.circle").font(.system(size: 23)) }
            }.foregroundStyle(Palette.accent).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(active ? "\(song.title)の試し聞きを停止" : "\(song.title)を15秒試し聞き")
            .accessibilityIdentifier("preview-song-" + song.id)
    }
}

struct PreviewBanner: View {
    @ObservedObject var preview: PreviewController
    var body: some View {
        if let song = preview.song {
            HStack(spacing: 10) {
                if preview.loading { ProgressView().tint(Palette.accent) }
                else { Image(systemName: "headphones").foregroundStyle(Palette.accent) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(preview.loading ? "試し聞きを準備中…" : (preview.window?.label ?? "試し聞き") + " · 曲は保存しません")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark.circle.fill", label: "試し聞きを停止", size: 22) { preview.stop() }
            }.foregroundStyle(Palette.text).padding(.leading, 14).padding(.trailing, 3).padding(.vertical, 4)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11))
                .padding(.horizontal, 8).padding(.bottom, 6).accessibilityIdentifier("preview-banner")
        }
    }
}
