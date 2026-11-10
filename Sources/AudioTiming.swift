import AVFoundation

struct AudioTiming {
    let duration: Double
    let containerDuration: Double

    /// Count audio frames independently of the movie/container duration and saved index.
    static func read(_ url: URL) async throws -> AudioTiming {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) { () async throws -> AudioTiming in
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let containerDuration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            let playable = try await asset.load(.isPlayable)
            guard playable, audio.count == 1, video.isEmpty else { throw AppFailure("保存したデータを音楽として確認できません。") }
            guard duration.isFinite, duration > 0 else { throw AppFailure("音声の再生時間を確認できません。") }
            return AudioTiming(duration: duration, containerDuration: containerDuration)
        }
        return try await withTaskCancellationHandler {
            let timing = try await work.value
            try Task.checkCancellation()
            return timing
        } onCancel: { work.cancel() }
    }
}
