import XCTest
@testable import UTubeMusic

final class DataUsageTests: XCTestCase {
    func testMetadataReusesResponseUntilExpiryButStreamLinksAreAlwaysFresh() async throws {
        var calls = 0
        var time = 100.0
        let engine = PythonService(call: { text in
            calls += 1
            if text.contains("resolve") {
                return "{\"ok\":true,\"url\":\"https://r1.googlevideo.com/\(calls)\"}"
            }
            return "{\"ok\":true,\"suggestions\":[\"request-\(calls)\"]}"
        }, now: { time })
        let first = try await engine.request(["op": "suggestions", "query": "test"])
        let cached = try await engine.request(["query": "test", "op": "suggestions"])
        XCTAssertEqual(first.suggestions, ["request-1"])
        XCTAssertEqual(cached.suggestions, first.suggestions)

        time += 181
        let refreshed = try await engine.request(["op": "suggestions", "query": "test"])
        XCTAssertEqual(refreshed.suggestions, ["request-2"])

        let request = ["op": "resolve", "id": "01234567890"]
        let firstStream = try await engine.request(request)
        let secondStream = try await engine.request(request)
        XCTAssertNotEqual(firstStream.url, secondStream.url)
        XCTAssertEqual(calls, 4)
    }
}
