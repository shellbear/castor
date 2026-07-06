import Foundation

/// One file → fMP4 HLS conversion session.
///
/// Remux mode (`-c copy`) runs hundreds of times faster than realtime, so the
/// whole file is repackaged ahead and ffmpeg's own playlist is served.
/// Transcode mode serves a predicted VOD playlist; when the player requests a
/// segment far from the encode head (a seek), ffmpeg is restarted at that
/// segment with matching timestamp offsets.
public actor HLSSession {
    public enum Mode: Sendable {
        case remux
        case transcode
    }

    public enum SessionError: Error {
        case invalidFileName
        case timedOutWaiting(String)
        case ffmpegFailed(String)
    }

    public let id = UUID().uuidString.lowercased()
    public let directory: URL

    private let media: MediaInfo
    private let plan: PlayPlan
    private let tools: FFTools
    private let segmentDuration: Double
    private let process = FFmpegProcess()
    private var currentStartSegment = 0
    private var started = false

    public var mode: Mode {
        plan.video == .encodeH264 ? .transcode : .remux
    }

    public init(
        media: MediaInfo,
        plan: PlayPlan,
        tools: FFTools,
        segmentDuration: Double = 6
    ) throws {
        self.media = media
        self.plan = plan
        self.tools = tools
        self.segmentDuration = segmentDuration
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("castor-hls-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        try await launch(fromSegment: 0)
    }

    public func stop() async {
        await process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Content

    public func playlistData() async throws -> Data {
        switch mode {
        case .transcode:
            return Data(HLSPlaylist.vod(
                duration: media.durationSeconds,
                segmentDuration: segmentDuration
            ).utf8)
        case .remux:
            // ffmpeg writes the real playlist (variable, keyframe-aligned
            // segment durations); remux-ahead finishes in seconds.
            let url = directory.appendingPathComponent("index.m3u8")
            try await waitForFile(url, timeout: 15)
            return try Data(contentsOf: url)
        }
    }

    /// Returns the on-disk URL for a requested file once it exists,
    /// restarting the encoder for out-of-window seeks in transcode mode.
    public func fileURL(forRequested name: String) async throws -> URL {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
              !name.hasPrefix(".")
        else { throw SessionError.invalidFileName }

        let url = directory.appendingPathComponent(name)
        guard let segment = HLSPlaylist.segmentNumber(fromName: name) else {
            try await waitForFile(url, timeout: 15)
            return url
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        if mode == .transcode {
            let head = highestExistingSegment() ?? (currentStartSegment - 1)
            let isBehindCurrentRun = segment < currentStartSegment
            let isFarAhead = segment > head + 4
            if isBehindCurrentRun || isFarAhead {
                try await launch(fromSegment: segment)
            }
        }

        try await waitForFile(url, timeout: 30)
        return url
    }

    // MARK: - Internals

    private func launch(fromSegment segment: Int) async throws {
        await process.terminate()
        currentStartSegment = segment
        let args = FFmpegArgs.hls(
            media: media,
            plan: plan,
            startSegment: segment,
            segmentDuration: segmentDuration,
            directory: directory
        )
        try await process.start(tool: tools.ffmpeg, arguments: args)
    }

    private func highestExistingSegment() -> Int? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(HLSPlaylist.segmentNumber(fromName:)).max()
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            if await !process.isRunning, highestExistingSegment() == nil,
               url.lastPathComponent != "index.m3u8" || mode == .remux {
                // ffmpeg died before producing anything.
                let stderr = await process.lastErrorOutput
                if !stderr.isEmpty {
                    throw SessionError.ffmpegFailed(stderr)
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SessionError.timedOutWaiting(url.lastPathComponent)
    }
}
