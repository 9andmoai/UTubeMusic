import SwiftUI

actor ArtworkCache {
    static let shared = ArtworkCache()

    private let session: URLSession
    private let recent = NSCache<NSURL, NSData>()
    private var pending: [URL: Task<Data?, Never>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("UTubeMusic-Artwork", isDirectory: true)
            configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024,
                                              directory: directory)
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 12
            self.session = URLSession(configuration: configuration)
        }
        recent.countLimit = 128
        recent.totalCostLimit = 8 * 1024 * 1024
    }

    func data(for url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        if let cached = recent.object(forKey: url as NSURL) { return cached as Data }
        if let task = pending[url] { return await task.value }
        let task = Task { [session] () -> Data? in
            guard let (data, response) = try? await session.data(from: url),
                  let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", data.count < 8_000_000,
                  UIImage(data: data) != nil else { return nil }
            return data
        }
        pending[url] = task
        let data = await task.value
        pending[url] = nil
        if let data { recent.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
        return data
    }
}

struct ArtworkImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (URL, UIImage)?

    var body: some View {
        Group {
            if let loaded, loaded.0 == url {
                Image(uiImage: loaded.1).resizable().scaledToFill()
            } else { placeholder() }
        }
        .task(id: url) {
            guard loaded?.0 != url else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let data = await ArtworkCache.shared.data(for: url),
                  !Task.isCancelled, let image = UIImage(data: data) else { return }
            loaded = (url, image)
        }
    }
}
