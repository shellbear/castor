import Foundation

public struct MediaProber: Sendable {
    private let tools: FFTools

    public init(tools: FFTools) {
        self.tools = tools
    }

    public func probe(_ url: URL) async throws -> MediaInfo {
        let json = try await Subprocess.run(tools.ffprobe, arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path,
        ])
        return try MediaInfo(ffprobeJSON: json, url: url)
    }
}
