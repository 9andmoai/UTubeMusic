import Foundation

/// Search/video duration is display-only. Only stream or media timing can end playback.
enum OnlineTiming {
    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 86400 else { return nil }
        return value
    }
    static func endpoint(stream: Double?, media: Double?) -> Double? {
        let source = valid(stream), actual = valid(media)
        if let actual {
            // Prefer native media timing for ordinary subsecond offsets. Only
            // use format timing to repair a clearly overstated container length.
            if let source, actual-source > max(1, source*0.1) { return source }
            return actual
        }
        return source
    }
}

struct PlaybackProgress {
    enum Action: Equatable { case none, finish, recover, failed }
    private var position: Double?
    private var changedAt = 0.0
    mutating func reset() { position = nil; changedAt = 0 }
    mutating func observe(position value: Double, endpoint: Double?, now: Double, wantsPlayback: Bool, recoveries: Int) -> Action {
        guard wantsPlayback, value.isFinite, value >= 0 else { reset(); return .none }
        if position == nil || abs(value-position!) > 0.015 {
            position = value; changedAt = now; return .none
        }
        let stalled = max(0, now-changedAt)
        if let end = OnlineTiming.valid(endpoint), value >= end-0.04, stalled >= 2 { return .finish }
        if stalled >= 12 { return recoveries == 0 ? .recover : .failed }
        return .none
    }
}
