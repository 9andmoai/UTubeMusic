import AVFoundation

struct PreviewWindow {
    let start: Double
    let end: Double
    let kind: String
    var label: String {
        let seconds = Int(ceil(end - start))
        return (kind == "chorus" ? "サビの位置から" : kind == "beginning" ? "冒頭から" : "曲の途中から") + "\(seconds)秒"
    }
    init(start: Double, end: Double, kind: String) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 15.01 else {
            throw AppFailure("試し聞きの再生位置を確認できません。")
        }
        self.start = start; self.end = end; self.kind = kind
    }
    static func middle(duration: Double) throws -> Self {
        let start = duration > 15 ? min(duration * 0.4, duration - 15) : 0
        return try Self(start: start, end: min(duration, start + 15), kind: start > 0 ? "middle" : "beginning")
    }
}

@MainActor
final class PreviewController: ObservableObject {
    @Published private(set) var song: Song?
    @Published private(set) var loading = false
    @Published private(set) var window: PreviewWindow?
    var normalizationEnabled = true {
        didSet { player.volume = normalizationEnabled ? normalizedVolume : 1 }
    }
    private var normalizedVolume: Float = 1
    private let player = AVPlayer()
    private let request: ([String: String]) async throws -> EngineResponse
    private let itemFactory: (URL, [String: String]) -> AVPlayerItem
    private let suspendMain: () -> Bool
    private let resumeMain: () -> Void
    private let onError: (String) -> Void
    private var resumeAfter = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var starting = false
    private var ended: NSObjectProtocol?
    private var failed: NSObjectProtocol?

    init(request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) },
         itemFactory: @escaping (URL, [String: String]) -> AVPlayerItem = { url, headers in
             var options: [String: Any] = [:]
             if let agent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                 options[AVURLAssetHTTPUserAgentKey] = agent
             }
             return AVPlayerItem(asset: AVURLAsset(url: url, options: options))
         }, suspendMain: @escaping () -> Bool, resumeMain: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.request = request; self.itemFactory = itemFactory
        self.suspendMain = suspendMain; self.resumeMain = resumeMain; self.onError = onError
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in guard let self, self.matches(item) else { return }; self.stop() }
        }
        failed = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.matches(item) else { return }
                self.fail("試し聞きの通信が途切れました。再試行してください。")
            }
        }
    }
    deinit {
        if let ended { NotificationCenter.default.removeObserver(ended) }
        if let failed { NotificationCenter.default.removeObserver(failed) }
    }
    func toggle(_ value: Song, localURL: URL? = nil) {
        if song?.id == value.id { stop(); return }
        let resume = song == nil ? suspendMain() : resumeAfter
        stop(resume: false)
        resumeAfter = resume; song = value; loading = true
        let token = generation
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.fail("試し聞きの準備に時間がかかっています。通信を確認して再試行してください。")
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url: URL, headers: [String: String], segment: PreviewWindow, volume: Float
                if let localURL {
                    let timing = try await AudioTiming.read(localURL)
                    url = localURL; headers = [:]; segment = try .middle(duration: timing.duration)
                    volume = normalizationEnabled ? Loudness.volume(lufs: try? await Loudness.read(localURL)) : 1
                } else {
                    let response = try await request(["op": "preview", "id": value.id])
                    guard let text = response.url, let resolved = URL(string: text), resolved.scheme == "https",
                          resolved.host?.hasSuffix(".googlevideo.com") == true,
                          let start = response.preview_start, let end = response.preview_end else {
                        throw AppFailure("試し聞きの音声を取得できません。")
                    }
                    if let duration = response.song?.duration, duration > 0, end > duration + 0.1 {
                        throw AppFailure("試し聞きの再生範囲を確認できません。")
                    }
                    volume = Loudness.sourceVolume(response.loudness_db)
                    url = resolved; headers = response.headers ?? [:]
                    segment = try PreviewWindow(start: start, end: end, kind: response.preview_kind ?? "middle")
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                normalizedVolume = volume
                window = segment
                let item = itemFactory(url, headers)
                item.preferredForwardBufferDuration = 3
                item.forwardPlaybackEndTime = CMTime(seconds: segment.end, preferredTimescale: 600)
                player.volume = normalizationEnabled ? normalizedVolume : 1
                player.replaceCurrentItem(with: item)
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor in
                        guard let self, self.generation == token, self.player.currentItem === item else { return }
                        if status == .failed { self.fail("この曲は試し聞きできません。通信や取得元の制限を確認してください。") }
                        else if status == .readyToPlay && !self.starting {
                            self.starting = true
                            self.player.seek(to: CMTime(seconds: segment.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { success in
                                Task { @MainActor in
                                    guard self.generation == token, self.player.currentItem === item else { return }
                                    guard success else { self.fail("試し聞きの再生位置へ移動できません。再試行してください。"); return }
                                    do {
                                        try AVAudioSession.sharedInstance().setActive(true)
                                        self.loading = false; self.timeout?.cancel(); self.player.play()
                                    } catch { self.fail(error.localizedDescription) }
                                }
                            }
                        }
                    }
                }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                fail(error.localizedDescription)
            }
        }
    }
    func matches(_ item: AVPlayerItem) -> Bool { song != nil && item === player.currentItem }
    func fail(_ message: String) { stop(); onError(message) }
    func stop(resume: Bool = true) {
        let restore = resume && resumeAfter
        resumeAfter = false; generation = UUID()
        task?.cancel(); task = nil; timeout?.cancel(); timeout = nil
        observation = nil; player.pause(); player.replaceCurrentItem(with: nil)
        song = nil; window = nil; loading = false; starting = false
        if restore { resumeMain() }
    }
}
