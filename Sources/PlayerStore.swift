import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var current: Song?
    @Published private(set) var playing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var searchPlayback = false
    @Published private(set) var resolvingOnline = false
    private var searchSongs: [String: Song] = [:]
    @Published var error: String?
    @Published var normalizeVolume = UserDefaults.standard.object(forKey: "normalizeVolume") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(normalizeVolume, forKey: "normalizeVolume")
            player.volume = normalizeVolume ? normalizedVolume : 1
            preview.normalizationEnabled = normalizeVolume
            if normalizeVolume, let current, library.isAvailable(current), current.loudnessFileName != current.fileName {
                let position = elapsed, resume = playing
                load(current, autoplay: resume); seek(position)
            }
        }
    }
    @Published var autoSkipIntro = UserDefaults.standard.object(forKey: "autoSkipIntro") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSkipIntro, forKey: "autoSkipIntro") }
    }
    @Published private(set) var preparingIntro = false
    private var introTask: Task<Void, Never>?
    private var playAfterIntro = false
    private let introProbe: (URL, [String: String]) async -> Double?
    private var normalizedVolume: Float = 1
    private var volumeTask: Task<Void, Never>?
    @Published private(set) var preparingVolume = false
    private var playAfterVolume = false
    private var needsStartPosition = false
    private var seekingStart = false
    private var waitingForStartReadiness = false
    private var playAfterStart = false
    private var startSeekGeneration = UUID()
    var preparingStartPosition: Bool { seekingStart || waitingForStartReadiness }
    var playbackButtonSymbol: String { playing || resolvingOnline || buffering ? "pause.fill" : "play.fill" }
    var playbackButtonLabel: String { playbackButtonSymbol == "pause.fill" ? "一時停止" : "再生" }
    @Published private(set) var alternateAudioID: String?
    private var alternateIntroOffset: Double?
    private let recentIntroOffsets = NSCache<NSString, NSNumber>()
    var lyricsSongID: String? {
        guard !resolvingOnline, let current, current.hasYouTubeSource else { return nil }
        return alternateAudioID ?? current.id
    }
    var playbackVolume: Float { player.volume }
    private let player = AVPlayer()
    private let request: ([String: String]) async throws -> EngineResponse
    private let streamItem: (URL, [String: Any]) -> AVPlayerItem
    private let library: LibraryStore
    @Published private(set) var buffering = false
    private var wantsPlayback = false
    private var playbackWatch: Task<Void, Never>?
    private var progress = PlaybackProgress()
    private var recoveryAttempts = 0
    private var onlineItem: AVPlayerItem?
    private var sourceAudioDuration: Double?
    private var onlineDurationObservation: NSKeyValueObservation?
    private var finishedItem: AVPlayerItem?
    private var resumePosition: Double?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = UUID()
    private var durationTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var artwork: MPMediaItemArtwork?
    lazy var preview = PreviewController(suspendMain: { [weak self] in
        guard let self else { return false }
        let resume = self.playing; self.pauseMain(); return resume
    }, resumeMain: { [weak self] in self?.play() }, onError: { [weak self] message in self?.error = message })

    func togglePreview(_ song: Song) {
        let saved = library.song(song.id)
        let local = saved.flatMap { library.isAvailable($0) ? library.file($0.fileName) : nil }
        preview.normalizationEnabled = normalizeVolume
        preview.toggle(song, localURL: local)
    }

    init(library: LibraryStore,
         introProbe: @escaping (URL, [String: String]) async -> Double? = { await IntroSilence.remote($0, headers: $1) },
         request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) },
         streamItem: @escaping (URL, [String: Any]) -> AVPlayerItem = { AVPlayerItem(asset: AVURLAsset(url: $0, options: $1)) }) {
        recentIntroOffsets.countLimit = 128
        self.introProbe = introProbe
        self.request = request; self.streamItem = streamItem
        self.library = library
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
        catch { self.error = error.localizedDescription }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if time.seconds.isFinite { self.elapsed = max(0, time.seconds) }
                self.playing = self.player.rate > 0
                self.updateNowPlaying()
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem,
                      self.preview.song == nil else { return }
                self.finishPlayback(item)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.playing; self.pause()
                } else if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.play()
                }
                if type != AVAudioSession.InterruptionType.began.rawValue { self.resumeAfterInterruption = false }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.pause(); self.error = "この曲を最後まで再生できませんでした。再保存を試してください。"
            }
        })
        configureCommands()
    }
    func start(_ songs: [Song], at song: Song, shuffle: Bool = false, fromSearch: Bool = false) {
        let available = songs.compactMap { candidate -> Song? in
            let saved = library.song(candidate.id)
            if let saved, library.isPlayable(saved) { return saved }
            if fromSearch, candidate.hasYouTubeSource {
                var stream = candidate
                stream.onlineOnly = true
                return stream
            }
            return saved == nil && library.isPlayable(candidate) ? candidate : nil
        }
        guard let selected = available.first(where: { $0.id == song.id }) else {
            error = "音声ファイルが見つかりません。検索からオンライン再生を試してください。"
            return
        }
        searchSongs = fromSearch ? Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        searchPlayback = fromSearch
        error = nil
        queue.start(available.map(\.id), at: song.id, shuffle: shuffle)
        load(selected)
    }

    func queuedSong(_ id: String) -> Song? {
        if let saved = library.song(id), library.isPlayable(saved) { return saved }
        return searchSongs[id]
    }
    private var currentStartOffset: Double {
        guard let current else { return 0 }
        if alternateAudioID != nil {
            return autoSkipIntro ? min(alternateIntroOffset ?? 0, max(0, duration - 0.5)) : 0
        }
        return (queuedSong(current.id) ?? current).startOffset(duration: duration, automatic: autoSkipIntro)
    }

    func play() {
        preview.stop(resume: false)
        guard let current else { return }
        if resolvingOnline { return }
        if player.currentItem == nil, current.onlineOnly == true { load(current); return }
        if preparingIntro { playAfterIntro = true; return }
        if preparingVolume { playAfterVolume = true; return }
        if seekingStart { playAfterStart = true; return }
        if needsStartPosition {
            let offset = resumePosition ?? currentStartOffset
            if offset > 0, let item = player.currentItem {
                if item.status != .readyToPlay {
                    waitingForStartReadiness = true; playAfterStart = true; return
                }
                needsStartPosition = false
                let token = UUID(); startSeekGeneration = token
                seekingStart = true; playAfterStart = true
                player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] success in
                    Task { @MainActor in
                        guard let self, let item, self.player.currentItem === item, self.startSeekGeneration == token else { return }
                        self.seekingStart = false
                        let resume = self.playAfterStart; self.playAfterStart = false
                        guard success else { self.pause(); self.error = "設定した開始位置に移動できませんでした。再生をやり直してください。"; return }
                        self.elapsed = offset; self.updateNowPlaying()
                        if resume { self.play() }
                    }
                }
                return
            }
            needsStartPosition = false
        }
        if duration > 0 && elapsed >= duration - 0.005 { seek(currentStartOffset) }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            wantsPlayback = true; finishedItem = nil
            player.play(); playing = true; startPlaybackWatch(); updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    private func pauseMain() { wantsPlayback = false; buffering = false; playbackWatch?.cancel(); playbackWatch = nil; progress.reset(); playAfterIntro = false; playAfterStart = false; playAfterVolume = false; player.pause(); playing = false; updateNowPlaying() }
    func pause() {
        streamGeneration = UUID()
        streamTask?.cancel()
        if resolvingOnline { preparingIntro = false }
        resolvingOnline = false
        preview.stop(resume: false)
        pauseMain()
    }
    func toggle() {
        if resolvingOnline || buffering { pause(); return }
        if preparingIntro { playAfterIntro ? pause() : play(); return }
        if seekingStart || waitingForStartReadiness { playAfterStart ? pause() : play(); return }
        if preparingVolume { playAfterVolume ? pause() : play(); return }
        if preview.song != nil { preview.stop(resume: false) }
        else { playing ? pause() : play() }
    }
    func seek(_ seconds: Double) {
        preview.stop(resume: false)
        guard seconds.isFinite else { return }
        resetStartPreparation(); progress.reset(); finishedItem = nil
        elapsed = min(max(0, seconds), max(0, duration))
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }
    func next(automatically: Bool = false) {
        preview.stop(resume: false)
        // Skip missing files, without recursion or an infinite repeat loop.
        var inspected = Set<String>()
        while let id = queue.advance(automatically: automatically) {
            guard inspected.insert(id).inserted else { break }
            if let song = queuedSong(id), library.isPlayable(song) { load(song); return }
        }
        pause()
        if automatically { seek(duration) }
    }
    func previous() {
        preview.stop(resume: false)
        let offset = currentStartOffset
        if elapsed > offset + 3 { seek(offset); return }
        if let id = queue.previous(), let song = queuedSong(id), library.isPlayable(song) { load(song) }
        else { seek(offset) }
    }
    func toggleShuffle() { queue.toggleShuffle() }
    func toggleRepeat() { queue.repeatMode = queue.repeatMode.next }
    func enqueue(_ song: Song) {
        if current == nil { start([song], at: song) } else { queue.append(song.id) }
    }
    func remove(_ id: String) {
        let wasCurrent = current?.id == id
        searchSongs.removeValue(forKey: id)
        queue.remove(id)
        if wasCurrent {
            introTask?.cancel(); preparingIntro = false; resetStartPreparation(); pause(); volumeTask?.cancel(); preparingVolume = false; player.replaceCurrentItem(with: nil); current = nil; elapsed = 0; duration = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if let next = queue.current, let song = queuedSong(next), library.isPlayable(song) { load(song) }
        }
    }
    func refreshAfterAudioRepair() {
        guard let current, let updated = library.song(current.id),
              updated.fileName != current.fileName || updated.duration != current.duration else { return }
        let position = elapsed, wasPlaying = playing
        load(updated, autoplay: wasPlaying)
        seek(min(position, updated.duration))
    }
    func releaseRemovedDownload(_ id: String) {
        if preview.song?.id == id { preview.stop(resume: current?.id != id) }
        guard current?.id == id else { return }
        introTask?.cancel(); preparingIntro = false; resetStartPreparation(); pause()
        volumeTask?.cancel(); preparingVolume = false
        durationTask?.cancel(); statusObservation = nil
        player.replaceCurrentItem(with: nil)
        alternateAudioID = nil; alternateIntroOffset = nil
        current = library.song(id)
        elapsed = 0; duration = current?.duration ?? 0
        updateNowPlaying()
        // Keep queue position, shuffle order and repeat mode. The next play
        // resolves the online audio instead of continuing an unlinked local file.
    }
    private func finishStartReadiness() {
        guard waitingForStartReadiness else { return }
        waitingForStartReadiness = false
        if playAfterStart { play() }
    }
    private func resetStartPreparation() {
        resumePosition = nil; startSeekGeneration = UUID(); waitingForStartReadiness = false; seekingStart = false; playAfterStart = false; needsStartPosition = false
    }
    private func load(_ song: Song, autoplay: Bool = true, resumeAt: Double? = nil, recovering: Bool = false) {
        playbackWatch?.cancel(); playbackWatch = nil; wantsPlayback = false; buffering = false; progress.reset()
        onlineItem = nil; onlineDurationObservation = nil; sourceAudioDuration = nil; finishedItem = nil
        if !recovering { recoveryAttempts = 0 }
        preview.stop(resume: false)
        let song = queuedSong(song.id) ?? song
        alternateAudioID = nil; alternateIntroOffset = nil
        resolvingOnline = false
        introTask?.cancel(); preparingIntro = false; playAfterIntro = false
        resetStartPreparation(); resumePosition = resumeAt; needsStartPosition = true
        streamGeneration = UUID(); streamTask?.cancel()
        volumeTask?.cancel(); preparingVolume = false; playAfterVolume = false
        normalizedVolume = 1; player.volume = 1
        if !library.isAvailable(song), song.onlineOnly == true {
            loadOnline(song, autoplay: autoplay); return
        }
        guard let url = library.file(song.fileName), library.isAvailable(song) else { error = "音声ファイルが見つかりません。"; return }
        statusObservation = nil
        durationTask?.cancel()
        player.pause()
        let item = AVPlayerItem(url: url)
        current = song; elapsed = 0; duration = song.duration
        if song.audioTimingVersion == 1, duration.isFinite, duration > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 44100)
        } else {
            durationTask = Task { [weak self, weak item] in
                do {
                    let timing = try await AudioTiming.read(url)
                    try Task.checkCancellation()
                    guard let self, let item, self.player.currentItem === item, self.current?.id == song.id else { return }
                    self.duration = timing.duration
                    self.current?.duration = timing.duration
                    item.forwardPlaybackEndTime = CMTime(seconds: timing.duration, preferredTimescale: 44100)
                    if let fileName = song.fileName {
                        do { try self.library.updateAudioDuration(song.id, expectedFileName: fileName,
                                                                  duration: timing.duration) }
                        catch { self.library.message = error.localizedDescription }
                    }
                    self.updateNowPlaying()
                } catch is CancellationError { }
                catch {
                    guard let self, let item, self.player.currentItem === item else { return }
                    self.pause(); self.error = error.localizedDescription
                }
            }
        }
        artwork = nil
        if let url = library.file(song.artworkName), let image = UIImage(contentsOfFile: url.path) {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let detail = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if failed { self.pause(); self.error = detail ?? "この曲を再生できません。" }
                else if item.status == .readyToPlay { self.finishStartReadiness() }
            }
        }
        playing = false
        if autoSkipIntro, song.introSkipSeconds == nil, song.detectedIntroSeconds == nil {
            preparingIntro = true; playAfterIntro = autoplay
            introTask = Task { [weak self, weak item] in
                let result = try? await IntroSilence.read(url)
                guard !Task.isCancelled, let self, let item, self.player.currentItem === item else { return }
                if let result { try? self.library.cacheDetectedIntro(song.id, seconds: result, fileName: song.fileName) }
                self.preparingIntro = false
                if self.playAfterIntro { self.play() }
            }
        }
        if normalizeVolume, song.loudnessFileName != song.fileName {
            preparingVolume = true; playAfterVolume = autoplay
            volumeTask = Task { [weak self, weak item] in
                let lufs: Double?, measured: Bool
                do { lufs = try await Loudness.read(url); measured = true }
                catch { lufs = nil; measured = false }
                guard !Task.isCancelled, let self, let item, self.player.currentItem === item else { return }
                self.normalizedVolume = Loudness.volume(lufs: lufs)
                self.player.volume = self.normalizeVolume ? self.normalizedVolume : 1
                if measured, let name = song.fileName { try? self.library.cacheLoudness(song.id, fileName: name, lufs: lufs) }
                self.preparingVolume = false
                if self.playAfterVolume { self.play() }
                self.updateNowPlaying()
            }
        } else {
            normalizedVolume = Loudness.volume(lufs: song.measuredLoudness)
            player.volume = normalizeVolume ? normalizedVolume : 1
            if autoplay { play() } else { updateNowPlaying() }
        }
    }
    private func loadOnline(_ song: Song, autoplay: Bool) {
        let token = streamGeneration
        durationTask?.cancel(); statusObservation = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        current = song; elapsed = 0; duration = song.duration; playing = false
        artwork = nil; resolvingOnline = true; updateNowPlaying()
        streamTask = Task { [weak self] in
            do {
                let response = try await self?.request(["op": "resolve", "id": song.id, "allow_official_audio": "1"])
                guard let response else { return }
                try Task.checkCancellation()
                guard let self, self.streamGeneration == token else { return }
                guard let text = response.url, let url = URL(string: text), url.scheme == "https",
                      url.host?.hasSuffix(".googlevideo.com") == true else { throw AppFailure("音声の取得先を確認できません。") }
                let alternate = response.audio_source_id
                let usesAlternate = alternate != nil
                if self.autoSkipIntro, usesAlternate || (song.introSkipSeconds == nil && song.detectedIntroSeconds == nil) {
                    self.preparingIntro = true
                    let source = (alternate ?? song.id) as NSString
                    let result: Double?
                    if let cached = self.recentIntroOffsets.object(forKey: source) {
                        result = cached.doubleValue
                    } else {
                        result = await self.introProbe(url, response.headers ?? [:])
                    }
                    guard !Task.isCancelled, self.streamGeneration == token else { return }
                    if let result, result.isFinite, (0...8).contains(result) {
                        self.recentIntroOffsets.setObject(NSNumber(value: result), forKey: source)
                        if usesAlternate {
                            self.alternateIntroOffset = result
                        } else {
                            self.current?.detectedIntroSeconds = result
                            if var candidate = self.searchSongs[song.id] {
                                candidate.detectedIntroSeconds = result
                                self.searchSongs[song.id] = candidate
                            }
                            try? self.library.cacheDetectedIntro(song.id, seconds: result, fileName: nil)
                        }
                    }
                    self.preparingIntro = false
                }
                var options: [String: Any] = [:]
                if let agent = response.headers?.first(where: { $0.key.lowercased() == "user-agent" })?.value { options[AVURLAssetHTTPUserAgentKey] = agent }
                self.normalizedVolume = Loudness.sourceVolume(response.loudness_db ?? (usesAlternate ? nil : song.sourceLoudnessDB))
                self.player.volume = self.normalizeVolume ? self.normalizedVolume : 1
                if !usesAlternate, self.library.song(song.id) != nil {
                    try? self.library.cacheSourceLoudness(song.id, db: response.loudness_db)
                }
                let item = self.streamItem(url, options)
                self.alternateAudioID = alternate
                self.onlineItem = item; self.sourceAudioDuration = OnlineTiming.valid(response.audio_duration)
                self.duration = response.song?.duration ?? song.duration
                // Rounded video/catalog metadata must not force an audio end time.
                self.onlineDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self, weak item] _, _ in
                    Task { @MainActor in
                        guard let self, let item, self.player.currentItem === item else { return }
                        self.refreshOnlineTiming(item)
                    }
                }
                item.preferredForwardBufferDuration = 8
                self.player.replaceCurrentItem(with: item)
                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        if item.status == .failed { self.pause(); self.error = "オンライン再生に失敗しました。通信を確認して再生し直してください。" }
                        else if item.status == .readyToPlay {
                            self.refreshOnlineTiming(item)
                            self.finishStartReadiness()
                        }
                    }
                }
                self.refreshOnlineTiming(item)
                self.resolvingOnline = false
                if autoplay { self.play() }
            } catch is CancellationError {} catch {
                guard let self, self.streamGeneration == token else { return }
                self.resolvingOnline = false; self.playing = false; self.error = error.localizedDescription
            }
        }
    }
    private func refreshOnlineTiming(_ item: AVPlayerItem) {
        guard item === player.currentItem, item === onlineItem else { return }
        let media = OnlineTiming.valid(item.duration.seconds)
        if let end = OnlineTiming.endpoint(stream: sourceAudioDuration, media: media) {
            duration = end; current?.duration = end
        }
        // Retain the prior DASH header repair only when AAC-format timing provides
        // an independent bound and the container is demonstrably longer.
        let bound: Double? = {
            guard let sourceAudioDuration, let media, media-sourceAudioDuration > max(1, sourceAudioDuration*0.1) else { return nil }
            return sourceAudioDuration
        }()
        let target = bound.map { CMTime(seconds: $0, preferredTimescale: 44100) } ?? .invalid
        if CMTimeCompare(item.forwardPlaybackEndTime, target) != 0 { item.forwardPlaybackEndTime = target }
        updateNowPlaying()
    }
    private func finishPlayback(_ item: AVPlayerItem) {
        guard item === player.currentItem, finishedItem !== item, wantsPlayback, preview.song == nil else { return }
        finishedItem = item; next(automatically: true)
    }
    private func startPlaybackWatch() {
        guard playbackWatch == nil, let item = player.currentItem else { return }
        playbackWatch = Task { [weak self, weak item] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, let item, self.player.currentItem === item, self.wantsPlayback else { return }
                if item === self.onlineItem { self.refreshOnlineTiming(item) }
                self.buffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let endpoint = item === self.onlineItem ? OnlineTiming.endpoint(stream: self.sourceAudioDuration, media: item.duration.seconds) : OnlineTiming.valid(self.duration)
                let action = self.progress.observe(position: item.currentTime().seconds, endpoint: endpoint,
                    now: ProcessInfo.processInfo.systemUptime,
                    wantsPlayback: self.wantsPlayback && !self.preparingVolume && !self.preparingIntro && !self.preparingStartPosition,
                    recoveries: self.recoveryAttempts)
                switch action {
                case .finish: self.finishPlayback(item); return
                case .recover:
                    guard item === self.onlineItem, let song = self.current else { continue }
                    let position = max(0, item.currentTime().seconds)
                    self.recoveryAttempts += 1
                    self.load(song, resumeAt: position, recovering: true); return
                case .failed:
                    guard item === self.onlineItem else { continue }
                    self.pause(); self.error = "オンライン再生が進まないため停止しました。通信を確認して再生し直してください。"; return
                case .none: break
                }
            }
        }
    }
    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title,
                                  MPMediaItemPropertyArtist: current.artist,
                                  MPMediaItemPropertyPlaybackDuration: duration,
                                  MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                                  MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
                                  MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.seek(seconds) }
            return .success
        }
    }
}
