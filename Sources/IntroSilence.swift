import AVFoundation

/// Detect only a near-silent prefix; never remove internal pauses or rewrite audio.
enum IntroSilence {
    static let scanSeconds = 8.0
    static let prefixLimit = 262144
    static func read(_ url: URL) async throws -> Double? {
        let task = Task.detached(priority: .userInitiated) { () throws -> Double? in
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard (1...2).contains(Int(format.channelCount)), format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }
            var detector = IntroSilenceDetector(rate: format.sampleRate)
            while file.framePosition < file.length && detector.frames < Int(format.sampleRate * scanSeconds) {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), file.length - file.framePosition))
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    var peak = 0.0
                    for channel in 0..<Int(format.channelCount) { peak = max(peak, abs(Double(samples[channel][frame]))) }
                    if let offset = detector.add(peak) { return offset }
                }
            }
            // No sustained sound found: do not guess where an intro should begin.
            return nil
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func validPrefix(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 206, response.url?.scheme == "https",
              response.url?.host?.hasSuffix(".googlevideo.com") == true,
              let range = AudioTransfer.parseRange(response.value(forHTTPHeaderField: "Content-Range") ?? "") else { return false }
        return range.start == 0 && range.end < prefixLimit
    }
    static func remote(_ url: URL, headers: [String: String]) async -> Double? {
        guard url.scheme == "https", url.host?.hasSuffix(".googlevideo.com") == true else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (key,value) in headers where ["user-agent", "referer", "origin", "accept", "accept-language"].contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(prefixLimit - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("intro-" + UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, validPrefix(http) else { return nil }
            var bytes = Data(); bytes.reserveCapacity(prefixLimit)
            for try await byte in stream {
                if bytes.count >= prefixLimit { break }
                if bytes.count % 4096 == 0 { try Task.checkCancellation() }
                bytes.append(byte)
            }
            try Task.checkCancellation()
            try bytes.write(to: temporary)
            return try await read(temporary)
        } catch { return nil }
    }
}

struct IntroSilenceDetector {
    let rate: Double
    private(set) var frames = 0
    private var energy = 0.0, samples = 0, activeWindows = 0
    private var firstSoundFrame = 0
    mutating func add(_ peak: Double) -> Double? {
        frames += 1; samples += 1
        if peak.isFinite { energy += peak * peak }
        guard samples >= max(1, Int(rate * 0.01)) else { return nil }
        // -70 dBFS RMS, 30 ms sustained audio; preserve 150 ms before onset.
        if energy / Double(samples) >= pow(10, -70.0 / 10) {
            if activeWindows == 0 { firstSoundFrame = frames - samples }
            activeWindows += 1
        } else { activeWindows = 0 }
        energy = 0; samples = 0
        guard activeWindows >= 3 else { return nil }
        let onset = Double(firstSoundFrame) / rate
        return onset >= 0.5 ? max(0, onset - 0.15) : 0
    }
}
