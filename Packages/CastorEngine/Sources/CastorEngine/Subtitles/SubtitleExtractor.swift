import Foundation

/// Converts embedded text subtitle tracks (SRT/ASS/…) to WebVTT — the one
/// format both Chromecast tracks and HLS renditions accept. Bitmap tracks
/// (PGS/VobSub) can't be converted this way; they need burn-in (roadmap).
public struct SubtitleExtractor: Sendable {
    private let tools: FFTools

    public init(tools: FFTools) {
        self.tools = tools
    }

    public func extractVTT(
        from media: MediaInfo,
        streamIndex: Int,
        into directory: URL
    ) async throws -> URL {
        let output = directory.appendingPathComponent("subtitle-\(streamIndex).vtt")
        try await Subprocess.run(tools.ffmpeg, arguments: [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", media.url.path,
            "-map", "0:\(streamIndex)",
            "-f", "webvtt",
            output.path,
        ])
        return output
    }

    /// The track to enable by default: a forced text track (signs, foreign
    /// dialogue) matching the audio language, else any forced text track.
    public static func defaultTrack(in media: MediaInfo, audioLanguage: String?) -> SubtitleStream? {
        let forced = media.subtitles.filter { $0.isTextBased && $0.isForced }
        if let audioLanguage, let match = forced.first(where: { $0.language == audioLanguage }) {
            return match
        }
        return forced.first
    }
}
