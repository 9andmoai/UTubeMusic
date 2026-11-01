import Foundation

struct Song: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    var duration: Double
    var thumbnail: String?
    var fileName: String?
    var artworkName: String?
    var bytes: Int64 = 0
    var favorite = false
    var addedAt = Date()
    var onlineOnly: Bool? = nil
    var audioTimingVersion: Int? = nil
    var measuredLoudness: Double? = nil
    var loudnessFileName: String? = nil
    var sourceLoudnessDB: Double? = nil
    var introSkipSeconds: Double? = nil
    var detectedIntroSeconds: Double? = nil

    func startOffset(duration actual: Double? = nil, automatic: Bool = true) -> Double {
        guard let value = introSkipSeconds ?? (automatic ? detectedIntroSeconds : nil), value.isFinite, value > 0 else { return 0 }
        let length = actual ?? duration
        let limit = length.isFinite && length > 0 ? min(30, max(0, length - 0.5)) : 30
        return min(value, limit)
    }

    var timeLabel: String { Self.clock(duration) }
    static func clock(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MusicPlaylist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var songIDs: [String] = []
    var createdAt = Date()
    var sourceOrder: [String]? = nil
    var sourceID: String? = nil
}

struct LibrarySnapshot: Codable {
    var version = 1
    var songs: [Song] = []
    var playlists: [MusicPlaylist] = []
}

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var label: String {
        switch self { case .off: return "リピートなし"; case .all: return "全曲リピート"; case .one: return "1曲リピート" }
    }
    var next: Self { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

// Queue order is stored explicitly: going back retraces the shuffled order.
struct PlaybackQueue {
    private(set) var original: [String] = []
    private(set) var order: [String] = []
    private(set) var index = 0
    private(set) var shuffled = false
    var repeatMode: RepeatMode = .off
    var current: String? { order.indices.contains(index) ? order[index] : nil }
    var upcoming: [String] { Array(order.dropFirst(index + 1)) }

    mutating func start(_ ids: [String], at id: String, shuffle: Bool = false) {
        var seen = Set<String>()
        original = ids.filter { seen.insert($0).inserted }
        shuffled = shuffle
        order = original
        index = order.firstIndex(of: id) ?? 0
        if shuffle, let current { order = [current] + original.filter { $0 != current }.shuffled(); index = 0 }
    }
    mutating func toggleShuffle() {
        guard let current else { return }
        shuffled.toggle()
        if shuffled { order = [current] + original.filter { $0 != current }.shuffled(); index = 0 }
        else { order = original; index = order.firstIndex(of: current) ?? 0 }
    }
    mutating func advance(automatically: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        if automatically && repeatMode == .one { return current }
        if index + 1 < order.count { index += 1; return current }
        guard repeatMode == .all else { return nil }
        if shuffled, let last = current, order.count > 1 {
            order.shuffle()
            if order.first == last { order.swapAt(0, 1) }
        }
        index = 0
        return current
    }
    mutating func previous() -> String? { index = max(0, index - 1); return current }
    mutating func remove(_ id: String) {
        let before = order.prefix(index).filter { $0 == id }.count
        original.removeAll { $0 == id }
        order.removeAll { $0 == id }
        index = min(max(0, index - before), max(0, order.count - 1))
    }
    mutating func append(_ id: String) {
        guard !original.contains(id) else { return }
        original.append(id); order.append(id)
    }
}

struct AppFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
