import XCTest
@testable import UTubeMusic

final class IntroSilenceTests: XCTestCase {
    func testSilenceAndQuietOnsetsKeepPreroll() {
        for amplitude in [0.1, 0.0005] {
            var detector = IntroSilenceDetector(rate: 10000)
            var result: Double?
            for n in 0..<30000 {
                if let offset = detector.add(n < 20000 ? 0 : abs(amplitude * sin(2 * .pi * 440 * Double(n) / 10000))) { result = offset; break }
            }
            XCTAssertEqual(result ?? 0, 1.85, accuracy: 0.03)
        }
    }
    func testImmediateMusicAndSilenceAreNotSkippedAndClicksAreIgnored() {
        var immediate = IntroSilenceDetector(rate: 10000)
        var result: Double?
        for _ in 0..<1000 { if let value = immediate.add(0.01) { result = value; break } }
        XCTAssertEqual(result, 0)
        var silent = IntroSilenceDetector(rate: 10000)
        for _ in 0..<80000 { XCTAssertNil(silent.add(0)) }
        var click = IntroSilenceDetector(rate: 10000)
        for n in 0..<24000 { XCTAssertNil(click.add(n == 10000 ? 1 : 0)) }
    }
    func testOnlinePrefixRejectsWholeFilesWrongHostsAndOversizedRanges() throws {
        let url = URL(string: "https://r1.googlevideo.com/audio")!
        func response(_ status: Int, _ range: String, url: URL) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": range])!
        }
        XCTAssertTrue(IntroSilence.validPrefix(response(206, "bytes 0-262143/999999", url: url)))
        XCTAssertFalse(IntroSilence.validPrefix(response(200, "bytes 0-262143/999999", url: url)))
        XCTAssertFalse(IntroSilence.validPrefix(response(206, "bytes 0-999998/999999", url: url)))
        XCTAssertFalse(IntroSilence.validPrefix(response(206, "bytes 0-262143/999999", url: URL(string: "https://example.com/audio")!)))
    }
    func testAACAndDASHPrefixDetectionDoesNotChangeAudio() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source))
        for name in ["intro_regular", "intro_dash"] {
            let bytes = try XCTUnwrap(fixtures[name].flatMap { Data(base64Encoded: $0) })
            for size in [bytes.count, min(bytes.count, 32768)] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                defer { try? FileManager.default.removeItem(at: url) }
                let prefix = Data(bytes.prefix(size)); try prefix.write(to: url)
                let offset = try await IntroSilence.read(url)
                XCTAssertEqual(try XCTUnwrap(offset), 1.85, accuracy: 0.16, "\(name), prefix \(size)")
                XCTAssertEqual(try Data(contentsOf: url), prefix)
            }
        }
    }
}
