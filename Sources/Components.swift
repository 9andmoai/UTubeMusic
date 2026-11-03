import SwiftUI

enum Palette {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.07)
    static let surface = Color(red: 0.105, green: 0.11, blue: 0.125)
    static let raised = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let accent = Color(red: 1, green: 0.39, blue: 0.31)
    static let text = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let secondary = Color(red: 0.64, green: 0.66, blue: 0.69)
}

struct IconButton: View {
    let symbol: String
    let label: String
    var color: Color = Palette.text
    var size: CGFloat = 21
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .foregroundStyle(color).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
struct TextActionButton: View {
    let title: String
    var font: Font
    let action: () -> Void
    init(_ title: String, font: Font = .subheadline, action: @escaping () -> Void) {
        self.title = title; self.font = font; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(font.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.bold)
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Palette.accent, in: Capsule()).foregroundStyle(Color.black).contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}
struct SongArtwork: View {
    let song: Song?
    var size: CGFloat = 56
    var radius: CGFloat = 10
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        Group {
            if let url = library.file(song?.artworkName), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let thumbnail = song?.thumbnail, let url = URL(string: thumbnail) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }.frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: radius))
            .accessibilityHidden(true)
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Palette.accent.opacity(0.55), Color(red: 0.18, green: 0.12, blue: 0.3), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: size * 0.35, weight: .light)).foregroundStyle(.white.opacity(0.6))
        }
    }
}
struct PlaylistArtwork: View {
    var name: String
    var favorite = false
    var size: CGFloat = 140
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: favorite ? [Color(red: 0.38, green: 0.24, blue: 0.7), Color(red: 0.11, green: 0.3, blue: 0.36)] : [Palette.accent.opacity(0.75), Color(red: 0.26, green: 0.16, blue: 0.32), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().stroke(.white.opacity(0.1), lineWidth: size * 0.14).frame(width: size * 0.8).offset(x: size * 0.4, y: -size * 0.35)
            Image(systemName: favorite ? "heart.fill" : "waveform").font(.system(size: size * 0.3, weight: .light))
                .foregroundStyle(.white.opacity(0.9)).padding(size * 0.14)
        }.frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(name)
    }
}
struct SectionTitle: View {
    var title: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Palette.text)
            if let caption { Text(caption).font(.caption).foregroundStyle(Palette.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent).padding(.bottom, 6)
            Text(title).font(.headline).foregroundStyle(Palette.text)
            Text(detail).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).lineSpacing(4)
        }.frame(maxWidth: .infinity).padding(.vertical, 38).padding(.horizontal, 24)
    }
}

struct SongRow: View {
    let song: Song
    var subtitle: String? = nil
    var trailing = "ellipsis"
    var trailingLabel: String? = nil
    var allowsPreview = false
    let action: () -> Void
    let more: () -> Void
    @EnvironmentObject private var player: PlayerStore
    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    SongArtwork(song: song)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.title).font(.subheadline.weight(.semibold)).foregroundStyle(player.current?.id == song.id ? Palette.accent : Palette.text).lineLimit(2)
                        Text(subtitle ?? song.artist).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if allowsPreview { PreviewButton(song: song) }
            IconButton(symbol: trailing, label: trailingLabel ?? (trailing == "arrow.down.circle" ? "\(song.title)を保存" : "\(song.title)のメニュー"), action: more)
        }.padding(.vertical, 6)
    }
}

// Visible in the active screen or sheet; avoids presenting an alert behind another modal.
struct AppFeedback: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = library.message ?? player.error {
                HStack(alignment: .top, spacing: 8) {
                    ScrollView { Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12) }
                        .frame(maxHeight: 180)
                    IconButton(symbol: "xmark", label: "お知らせを閉じる", size: 16) {
                        library.message = nil; player.error = nil
                    }
                }.padding(.leading, 16).padding(.trailing, 4)
                    .foregroundStyle(Palette.text).background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8).padding(12)
                    .accessibilityElement(children: .contain)
            }
        }
    }
}
extension View {
    func appFeedback() -> some View { modifier(AppFeedback()) }
}
