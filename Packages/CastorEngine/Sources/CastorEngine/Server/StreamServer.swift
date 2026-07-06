import FlyingFox
import FlyingSocks
import Foundation

/// The local HTTP server receivers pull media from. Serves shared files with
/// Range support and CORS headers (Chromecast requires CORS on everything).
public actor StreamServer {
    public enum ServerError: Error {
        case failedToBind
        case noLocalAddress
        case notRunning
    }

    public private(set) var boundPort: UInt16?
    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?
    private var files: [String: URL] = [:]
    private let hostOverride: String?

    /// - Parameter hostOverride: host to advertise in share URLs instead of
    ///   the LAN address (loopback in tests).
    public init(hostOverride: String? = nil) {
        self.hostOverride = hostOverride
    }

    public func start(preferredPort: UInt16 = 8410) async throws {
        guard server == nil else { return }
        var lastError: Error = ServerError.failedToBind

        for port in [preferredPort, preferredPort &+ 1, preferredPort &+ 8, 18410] {
            // Bind the IPv4 wildcard: receivers reach us over IPv4, and the
            // port-only initializer would bind IPv6 instead.
            let candidate = HTTPServer(address: sockaddr_in.inet(port: port))
            await registerRoutes(on: candidate)
            let task = Task { try await candidate.run() }
            do {
                try await candidate.waitUntilListening(timeout: 2)
                server = candidate
                runTask = Task { _ = try? await task.value }
                boundPort = port
                return
            } catch {
                task.cancel()
                lastError = error
            }
        }
        throw lastError
    }

    public func stop() async {
        await server?.stop()
        runTask?.cancel()
        server = nil
        runTask = nil
        boundPort = nil
        files.removeAll()
    }

    /// Registers a file and returns the URL a receiver on the LAN can fetch.
    /// The filename is kept in the URL (some receivers sniff the extension);
    /// the random token keeps the local path private.
    public func share(_ fileURL: URL) throws -> URL {
        guard let port = boundPort else { throw ServerError.notRunning }
        guard let host = hostOverride ?? LocalNetwork.primaryIPv4Address() else {
            throw ServerError.noLocalAddress
        }

        let token = UUID().uuidString.lowercased()
        files[token] = fileURL
        let name = fileURL.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
        guard let url = URL(string: "http://\(host):\(port)/v/\(token)/\(name)") else {
            files[token] = nil
            throw ServerError.noLocalAddress
        }
        return url
    }

    public func unshareAll() {
        files.removeAll()
    }

    // MARK: - Routes

    private func registerRoutes(on server: HTTPServer) async {
        await server.appendRoute("OPTIONS /*") { _ in
            HTTPResponse(statusCode: .noContent, headers: Self.withCORS([:]))
        }
        await server.appendRoute("GET /v/:token/:name") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .notFound) }
            return await self.fileResponse(for: request, headOnly: false)
        }
        await server.appendRoute("HEAD /v/:token/:name") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .notFound) }
            return await self.fileResponse(for: request, headOnly: true)
        }
    }

    private func fileResponse(for request: HTTPRequest, headOnly: Bool) -> HTTPResponse {
        guard let token = request.routeParameters["token"],
              let fileURL = files[token],
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int
        else {
            return HTTPResponse(statusCode: .notFound, headers: Self.withCORS([:]))
        }

        var headers: HTTPHeaders = [
            .contentType: MIMEType.forPathExtension(fileURL.pathExtension),
            .acceptRanges: "bytes",
        ]
        headers = Self.withCORS(headers)

        switch ByteRangeParse.parse(header: request.headers[.range], fileSize: fileSize) {
        case .invalid:
            headers[.contentRange] = "bytes */\(fileSize)"
            return HTTPResponse(
                statusCode: HTTPStatusCode(416, phrase: "Range Not Satisfiable"),
                headers: headers
            )

        case .partial(let range):
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileSize)"
            if headOnly {
                headers[.contentLength] = "\(range.count)"
                return HTTPResponse(statusCode: .partialContent, headers: headers)
            }
            guard let body = try? HTTPBodySequence(file: fileURL, range: range) else {
                return HTTPResponse(statusCode: .internalServerError, headers: headers)
            }
            return HTTPResponse(statusCode: .partialContent, headers: headers, body: body)

        case .none:
            if headOnly {
                headers[.contentLength] = "\(fileSize)"
                return HTTPResponse(statusCode: .ok, headers: headers)
            }
            guard let body = try? HTTPBodySequence(file: fileURL) else {
                return HTTPResponse(statusCode: .internalServerError, headers: headers)
            }
            return HTTPResponse(statusCode: .ok, headers: headers, body: body)
        }
    }

    private static func withCORS(_ headers: HTTPHeaders) -> HTTPHeaders {
        var headers = headers
        headers[HTTPHeader("Access-Control-Allow-Origin")] = "*"
        headers[HTTPHeader("Access-Control-Allow-Methods")] = "GET, HEAD, OPTIONS"
        headers[HTTPHeader("Access-Control-Allow-Headers")] = "Range, Content-Type"
        headers[HTTPHeader("Access-Control-Expose-Headers")] = "Content-Range, Content-Length, Accept-Ranges"
        return headers
    }
}
