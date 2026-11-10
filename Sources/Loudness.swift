import AVFoundation

/// Playback-only attenuation. Never amplify quiet recordings or rewrite audio.
enum Loudness {
    static func volume(lufs: Double?) -> Float {
        guard let lufs, lufs.isFinite, (-70...10).contains(lufs) else { return 1 }
        return Float(pow(10, min(0, -14 - lufs) / 20))
    }
    static func sourceVolume(_ db: Double?) -> Float {
        guard let db, db.isFinite, (-60...60).contains(db) else { return 1 }
        return Float(pow(10, -max(0, db) / 20))
    }
    static func read(_ url: URL) async throws -> Double? {
        let work = Task.detached(priority: .userInitiated) { () throws -> Double? in
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard (1...2).contains(Int(format.channelCount)), (8000...192000).contains(format.sampleRate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return nil }
            var meter = LoudnessMeter(rate: format.sampleRate, channels: Int(format.channelCount))
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let remaining = file.length - file.framePosition
                let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
                do { try file.read(into: buffer, frameCount: count) }
                catch { throw AppFailure("音量測定のPCM読取に失敗（位置 \(file.framePosition) / \(file.length)）：\(error.localizedDescription)") }
                guard buffer.frameLength > 0 else { break }
                guard let data = buffer.floatChannelData else { return nil }
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<Int(format.channelCount) {
                        meter.add(Double(data[channel][frame]), channel: channel)
                    }
                    meter.endFrame()
                }
            }
            return meter.integrated
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// Mono/stereo BS.1770 K weighting, 400 ms windows / 100 ms hops,
/// -70 LUFS absolute gate and -10 LU relative gate. Bounded PCM memory.
struct LoudnessMeter {
    private struct Filter {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func sample(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y
            return y
        }
    }
    private var shelf: [Filter], highpass: [Filter]
    private let hop: Int
    private var samples = 0, energy = 0.0
    private var hops: [Double] = [], blocks: [Double] = []
    init(rate: Double, channels: Int) {
        hop = max(1, Int((rate * 0.1).rounded()))
        let k = tan(.pi * 1681.974450955533 / rate), q = 0.7071752369554196
        let vh = pow(10.0, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        let d = 1 + k / q + k * k
        let pre = Filter(b0: (vh + vb * k / q + k*k) / d, b1: 2*(k*k-vh)/d,
                         b2: (vh-vb*k/q+k*k)/d, a1: 2*(k*k-1)/d, a2: (1-k/q+k*k)/d)
        let r = tan(.pi * 38.13547087602444 / rate), rq = 0.5003270373238773
        let rd = 1 + r/rq + r*r
        let post = Filter(b0: 1, b1: -2, b2: 1, a1: 2*(r*r-1)/rd, a2: (1-r/rq+r*r)/rd)
        shelf = Array(repeating: pre, count: channels); highpass = Array(repeating: post, count: channels)
    }
    mutating func add(_ sample: Double, channel: Int) {
        let value = highpass[channel].sample(shelf[channel].sample(sample.isFinite ? sample : 0))
        energy += value * value
    }
    mutating func endFrame() {
        samples += 1
        if samples == hop {
            hops.append(energy / Double(hop)); samples = 0; energy = 0
            if hops.count == 4 { blocks.append(hops.reduce(0, +) / 4); hops.removeFirst() }
        }
    }
    var integrated: Double? {
        let absolute = pow(10, (-70 + 0.691) / 10)
        let active = blocks.filter { $0.isFinite && $0 > absolute }
        guard !active.isEmpty else { return nil }
        let relative = active.reduce(0, +) / Double(active.count) / 10
        let gated = active.filter { $0 > relative }
        guard !gated.isEmpty else { return nil }
        return -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count))
    }
}
