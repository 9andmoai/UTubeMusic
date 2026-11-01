import SwiftUI

struct IntroSkipSheet: View {
    let song: Song
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var seconds: Double
    @State private var error: String?
    init(song: Song) { self.song = song; _seconds = State(initialValue: song.startOffset()) }
    private var limit: Double { song.duration > 0 ? min(30, max(0, song.duration - 0.5)) : 30 }
    private var label: String { String(format: "%.2f秒", seconds) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(song.title).font(.headline)
                    Text(song.artist).foregroundStyle(Palette.secondary)
                }
                Section("この曲の開始位置") {
                    LabeledContent("冒頭をスキップ", value: label)
                    if limit > 0 {
                        Slider(value: $seconds, in: 0...limit, step: 0.25).accessibilityLabel("冒頭を飛ばす秒数")
                        Stepper("0.25秒ずつ調整", value: $seconds, in: 0...limit, step: 0.25)
                    }
                    if player.current?.id == song.id {
                        Button("現在の再生位置を使う") { seconds = min(limit, max(0, player.elapsed)) }
                    }
                    Button("スキップしない（0秒）") { seconds = 0 }
                }
                Section {
                    Text("音が出始める少し手前を指定してください。保存すると、次回この曲を再生するときとリピート時に指定した位置から始まります。オンライン・ダウンロード済みの両方に対応します。")
                    Text("元の音声ファイル・お気に入り・プレイリストは変更しません。自動検出ではないため、静かなイントロがある曲は調整してください。再生時間は元の音源の位置を表示します。")
                }.font(.caption).foregroundStyle(Palette.secondary)
                if let error { Text(error).foregroundStyle(Palette.accent) }
            }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.text).tint(Palette.accent)
                .navigationTitle("冒頭の無音をスキップ").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do { try library.setIntroSkip(song.id, seconds: seconds); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }
    }
}
