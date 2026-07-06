import Foundation
import Testing
@testable import CastorEngine

@Suite struct StreamServerTests {
    private func makeTempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("castor-test-\(UUID().uuidString).mp4")
        let data = Data((0..<bytes).map { UInt8($0 % 251) })
        try data.write(to: url)
        return url
    }

    @Test func servesFullFileAndRanges() async throws {
        let fileURL = try makeTempFile(bytes: 100_000)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let server = StreamServer(hostOverride: "127.0.0.1")
        try await server.start(preferredPort: 8419)
        defer { Task { await server.stop() } }

        let shareURL = try await server.share(fileURL)

        // Full fetch.
        var request = URLRequest(url: shareURL)
        let (fullData, fullResponse) = try await URLSession.shared.data(for: request)
        let fullHTTP = try #require(fullResponse as? HTTPURLResponse)
        #expect(fullHTTP.statusCode == 200)
        #expect(fullData.count == 100_000)
        #expect(fullHTTP.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(fullHTTP.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(fullHTTP.value(forHTTPHeaderField: "Content-Type") == "video/mp4")

        // Bounded range — what players send while seeking.
        request.setValue("bytes=500-999", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: request)
        let rangeHTTP = try #require(rangeResponse as? HTTPURLResponse)
        #expect(rangeHTTP.statusCode == 206)
        #expect(rangeData.count == 500)
        #expect(rangeHTTP.value(forHTTPHeaderField: "Content-Range") == "bytes 500-999/100000")
        #expect(rangeData.first == UInt8(500 % 251))

        // Unsatisfiable range.
        request.setValue("bytes=200000-", forHTTPHeaderField: "Range")
        let (_, badResponse) = try await URLSession.shared.data(for: request)
        #expect((badResponse as? HTTPURLResponse)?.statusCode == 416)

        // Unknown token → 404.
        let badURL = shareURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("nonexistent/file.mp4")
        let (_, missing) = try await URLSession.shared.data(from: badURL)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }
}
