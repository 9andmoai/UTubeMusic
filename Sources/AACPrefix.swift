import Foundation

/// Reframe complete AAC-LC access units from a bounded MP4 prefix as ADTS.
/// No transcoding. Reject unsupported layouts instead of guessing byte offsets.
enum AACPrefix {
    private struct Box { let kind: String; let start: Int; let body: Int; let end: Int }
    private struct Reader {
        let bytes: [UInt8]
        func n(_ p: Int, _ width: Int = 4) -> Int? {
            guard p >= 0, width > 0, p <= bytes.count - width else { return nil }
            var value: UInt64 = 0
            for b in bytes[p..<p+width] { value = (value << 8) | UInt64(b) }
            guard value <= UInt64(Int.max) else { return nil }; return Int(value)
        }
        func boxes(_ start: Int, _ end: Int) -> [Box] {
            guard start >= 0, end <= bytes.count, start <= end else { return [] }
            var p = start, result: [Box] = []
            while p <= end - 8 {
                guard let size = n(p) else { break }
                let kind = String(bytes: bytes[p+4..<p+8], encoding: .ascii) ?? ""
                let header = size == 1 ? 16 : 8
                guard let length = size == 1 ? n(p+8, 8) : (size == 0 ? end-p : size), length >= header else { break }
                if length > end - p {
                    if kind == "mdat" { result.append(Box(kind: kind, start: p, body: p+header, end: end)) }
                    break
                }
                result.append(Box(kind: kind, start: p, body: p+header, end: p+length)); p += length
            }
            return result
        }
        func children(_ box: Box) -> [Box] { boxes(box.body, box.end) }
        func child(_ box: Box, _ kind: String) -> Box? { children(box).first { $0.kind == kind } }
        func descriptor(_ p: Int, _ end: Int) -> (tag: Int, body: Int, end: Int)? {
            guard p >= 0, p < end, end <= bytes.count else { return nil }
            let tag = Int(bytes[p]); var cursor = p+1, length = 0
            for _ in 0..<4 {
                guard cursor < end else { return nil }
                let b = Int(bytes[cursor]); cursor += 1; length = (length << 7) | (b & 127)
                if b & 128 == 0 { return length <= end-cursor ? (tag, cursor, cursor+length) : nil }
            }
            return nil
        }
        func config(_ esds: Box) -> (frequency: Int, channels: Int)? {
            guard let es = descriptor(esds.body+4, esds.end), es.tag == 3, es.body+3 <= es.end else { return nil }
            var p = es.body+3; let flags = bytes[es.body+2]
            if flags & 128 != 0 { p += 2 }
            if flags & 64 != 0 { guard p < es.end else { return nil }; p += 1 + Int(bytes[p]) }
            if flags & 32 != 0 { p += 2 }
            guard let decoder = descriptor(p, es.end), decoder.tag == 4, decoder.body+13 <= decoder.end,
                  bytes[decoder.body] == 0x40,
                  let asc = descriptor(decoder.body+13, decoder.end), asc.tag == 5, asc.body+2 <= asc.end else { return nil }
            let a = Int(bytes[asc.body]), b = Int(bytes[asc.body+1])
            let profile = a >> 3, frequency = ((a & 7) << 1) | (b >> 7), channels = (b >> 3) & 15
            guard profile == 2, frequency <= 12, (1...2).contains(channels) else { return nil }
            return (frequency, channels)
        }
    }
    static func adts(_ input: Data) -> Data? {
        guard input.count <= IntroSilence.prefixLimit, input.count >= 32 else { return nil }
        let r = Reader(bytes: Array(input)), top = Reader(bytes: Array(input)).boxes(0, input.count)
        guard let moov = top.first(where: { $0.kind == "moov" }),
              let trak = r.child(moov, "trak"), let mdia = r.child(trak, "mdia"),
              let handler = r.child(mdia, "hdlr"), handler.body+12 <= handler.end,
              String(bytes: r.bytes[handler.body+8..<handler.body+12], encoding: .ascii) == "soun",
              let minf = r.child(mdia, "minf"), let stbl = r.child(minf, "stbl"), let stsd = r.child(stbl, "stsd"),
              let entry = r.boxes(stsd.body+8, stsd.end).first, entry.kind == "mp4a", entry.body+28 <= entry.end,
              let esds = r.boxes(entry.body+28, entry.end).first(where: { $0.kind == "esds" }), let config = r.config(esds) else { return nil }
        var result = Data(), units = 0
        func append(_ offset: Int, _ size: Int) -> Bool {
            guard offset >= 0, size > 0, size <= 8184, offset <= r.bytes.count-size, units < 1024 else { return false }
            let length = size+7, channel = config.channels, frequency = config.frequency
            let header: [UInt8] = [0xff, 0xf1, UInt8(0x40 | (frequency << 2) | (channel >> 2)),
                                  UInt8(((channel & 3) << 6) | (length >> 11)), UInt8((length >> 3) & 255), UInt8(((length & 7) << 5) | 31), 0xfc]
            result.append(contentsOf: header); result.append(contentsOf: r.bytes[offset..<offset+size]); units += 1
            return true
        }
        // Conventional MP4 sample/chunk tables.
        if let stsz = r.child(stbl, "stsz"), let stsc = r.child(stbl, "stsc"),
           let offsets = r.child(stbl, "stco") ?? r.child(stbl, "co64"),
           let sampleSize = r.n(stsz.body+4), let count = r.n(stsz.body+8), count > 0,
           let runs = r.n(stsc.body+4), runs > 0, runs <= (stsc.end-stsc.body-8)/12,
           let chunks = r.n(offsets.body+4), chunks > 0 {
            let width = offsets.kind == "co64" ? 8 : 4
            guard chunks <= (offsets.end-offsets.body-8)/width,
                  sampleSize > 0 || count <= (stsz.end-stsz.body-12)/4 else { return nil }
            var sample = 0, run = 0
            for chunk in 1...chunks {
                while run+1 < runs, let first = r.n(stsc.body+8+(run+1)*12), first <= chunk { run += 1 }
                guard let perChunk = r.n(stsc.body+12+run*12), perChunk > 0, perChunk <= count,
                      var position = r.n(offsets.body+8+(chunk-1)*width, width) else { break }
                for _ in 0..<perChunk {
                    guard sample < count, let size = sampleSize > 0 ? sampleSize : r.n(stsz.body+12+sample*4), append(position,size) else { return result.isEmpty ? nil : result }
                    position += size; sample += 1
                }
            }
        } else {
            // Fragmented MP4 (DASH): trun packet sizes and data offsets.
            var defaultSize = 0, trackID: Int?
            if let mvex = r.child(moov, "mvex"), let trex = r.child(mvex, "trex") { trackID = r.n(trex.body+4); defaultSize = r.n(trex.body+16) ?? 0 }
            for moof in top where moof.kind == "moof" {
                guard let traf = r.child(moof,"traf"), let tfhd = r.child(traf,"tfhd"), let tf = r.n(tfhd.body),
                      let id = r.n(tfhd.body+4), trackID == nil || trackID == id else { continue }
                let flags = tf & 0xffffff
                var p = tfhd.body+8, base = moof.start, size = defaultSize
                if flags & 1 != 0 { guard let value = r.n(p,8) else { return nil }; base = value; p += 8 }
                if flags & 2 != 0 { p += 4 }; if flags & 8 != 0 { p += 4 }
                if flags & 16 != 0 { size = r.n(p) ?? 0; p += 4 }
                guard p <= tfhd.end else { return nil }
                var dataPosition = top.first(where: { $0.kind == "mdat" && $0.start >= moof.end })?.body ?? input.count
                for trun in r.children(traf) where trun.kind == "trun" {
                    guard let f = r.n(trun.body), let count = r.n(trun.body+4), count <= 16384 else { return nil }
                    let tf = f & 0xffffff; var cursor = trun.body+8
                    if tf & 1 != 0 {
                        guard let raw = r.n(cursor) else { return nil }
                        let delta = Int(Int32(bitPattern: UInt32(raw))); cursor += 4
                        guard delta >= -base, delta <= input.count-base else { return result.isEmpty ? nil : result }
                        dataPosition = base+delta
                    }
                    if tf & 4 != 0 { cursor += 4 }
                    for _ in 0..<count {
                        if tf & 0x100 != 0 { cursor += 4 }
                        var packetSize = size
                        if tf & 0x200 != 0 { packetSize = r.n(cursor) ?? 0; cursor += 4 }
                        if tf & 0x400 != 0 { cursor += 4 }; if tf & 0x800 != 0 { cursor += 4 }
                        guard cursor <= trun.end, append(dataPosition,packetSize) else { return result.isEmpty ? nil : result }
                        dataPosition += packetSize
                    }
                }
            }
        }
        return result.isEmpty ? nil : result
    }
}
