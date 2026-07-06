import Foundation

/// Locations of the ffmpeg/ffprobe executables Castor drives as subprocesses.
public struct FFTools: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Bundled binaries take priority (future work), then Homebrew (Apple
    /// Silicon), then /usr/local (Intel Homebrew, manual installs).
    public static func locate(bundle: Bundle = .main) -> FFTools? {
        var candidates: [(ffmpeg: String, ffprobe: String)] = []
        if let resources = bundle.resourceURL {
            candidates.append((
                resources.appendingPathComponent("ffmpeg").path,
                resources.appendingPathComponent("ffprobe").path
            ))
        }
        candidates.append(("/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe"))
        candidates.append(("/usr/local/bin/ffmpeg", "/usr/local/bin/ffprobe"))

        let fm = FileManager.default
        for candidate in candidates
        where fm.isExecutableFile(atPath: candidate.ffmpeg) && fm.isExecutableFile(atPath: candidate.ffprobe) {
            return FFTools(
                ffmpeg: URL(fileURLWithPath: candidate.ffmpeg),
                ffprobe: URL(fileURLWithPath: candidate.ffprobe)
            )
        }
        return nil
    }
}
