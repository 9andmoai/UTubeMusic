import SwiftUI

struct SearchSuggestions: View {
    let query: String
    let select: (String) -> Void
    private let request: ([String: String]) async throws -> EngineResponse
    @State private var values: [String] = []
    @State private var loading = false
    init(query: String, request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) }, select: @escaping (String) -> Void) {
        self.query = query; self.request = request; self.select = select
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button { select(value) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).frame(width: 22)
                        Text(value).font(.subheadline).multilineTextAlignment(.leading).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(Palette.secondary)
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(value)
                    .accessibilityIdentifier("search-suggestion-" + value)
                    .background { GeometryReader { geo in
                        Color.clear.preference(key: PlayerLayoutFrames.self, value: ["suggestion-" + value: geo.frame(in: .named("player-layout"))])
                    } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("検索候補を取得中") }
            else if values.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "曲名やアーティストを入力してください" : "キーボードの検索ボタンでも検索できます")
                    .font(.caption).foregroundStyle(Palette.secondary).padding(.vertical, 16)
            }
        }.foregroundStyle(Palette.text)
            .task(id: query) {
                values = []
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.contains("://") else { loading = false; return }
                loading = true
                defer { if !Task.isCancelled { loading = false } }
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                    let response = try await request(["op": "suggestions", "query": text])
                    try Task.checkCancellation()
                    var seen = Set<String>()
                    values = (response.suggestions ?? []).filter { seen.insert($0).inserted }
                } catch { }
            }
    }
}
