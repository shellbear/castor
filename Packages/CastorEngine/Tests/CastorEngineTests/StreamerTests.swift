import Foundation
import Testing
@testable import CastorEngine

// MARK: - Pure logic

@Suite struct HLSPlaylistTests {
    @Test func generatesFullVODPlaylist() {
        let playlist = HLSPlaylist.vod(duration: 20, segmentDuration: 6)
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(playlist.contains("#EXT-X-TARGETDURATION:6"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(playlist.contains("seg00000.m4s"))
        #expect(playlist.contains("seg00003.m4s"))
        #expect(!playlist.contains("seg00004.m4s"))
        #expect(playlist.contains("#EXTINF:2.000000,"))
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func exactMultipleHasNoRemainderSegment() {
        #expect(HLSPlaylist.segmentCount(duration: 12, segmentDuration: 6) == 2)
        #expect(HLSPlaylist.segmentCount(duration: 12.5, segmentDuration: 6) == 3)
    }

    @Test func segmentNameRoundTrip() {
        #expect(HLSPlaylist.segmentName(42) == "seg00042.m4s")
        #expect(HLSPlaylist.segmentNumber(fromName: "seg00042.m4s") == 42)
        #expect(HLSPlaylist.segmentNumber(fromName: "init.mp4") == nil)
        #expect(HLSPlaylist.segmentNumber(fromName: "index.m3u8") == nil)
    }
}

@Suite struct FFmpegArgsTests {
    private let hevcMKV = MediaInfo(
        url: URL(fileURLWithPath: "/tmp/movie.mkv"),
        container: "matroska,webm",
        durationSeconds: 4907,
        video: [VideoStream(index: 0, codec: "hevc", width: 1920, height: 1080, pixelFormat: "yuv420p10le")],
        audio: [AudioStream(index: 1, codec: "aac", channels: 6, isDefault: true)],
        subtitles: []
    )

    @Test func remuxCopiesAndTagsHVC1() {
        let plan = PlayPlan(video: .copy, audio: .copy, delivery: .hls, videoStreamIndex: 0, audioStreamIndex: 1)
        let args = FFmpegArgs.hls(
            media: hevcMKV, plan: plan, startSegment: 0, segmentDuration: 6,
            directory: URL(fileURLWithPath: "/tmp/out")
        )
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-c:v copy"))
        #expect(joined.contains("-tag:v hvc1"))
        #expect(joined.contains("-c:a copy"))
        #expect(joined.contains("-hls_segment_type fmp4"))
        #expect(joined.contains("-hls_flags temp_file"))
        #expect(!joined.contains("-hwaccel"))
        #expect(!joined.contains("-ss"))
    }

    @Test func transcodeUsesVideoToolboxAndForcedKeyframes() {
        let plan = PlayPlan(video: .encodeH264, audio: .copy, delivery: .hls, videoStreamIndex: 0, audioStreamIndex: 1)
        let args = FFmpegArgs.hls(
            media: hevcMKV, plan: plan, startSegment: 0, segmentDuration: 6,
            directory: URL(fileURLWithPath: "/tmp/out")
        )
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-hwaccel videotoolbox"))
        #expect(joined.contains("-c:v h264_videotoolbox"))
        #expect(joined.contains("-force_key_frames expr:gte(t,n_forced*6)"))
        #expect(!joined.contains("-tag:v hvc1"))
    }

    @Test func seekRestartOffsetsTimestamps() {
        let plan = PlayPlan(video: .encodeH264, audio: .encodeAAC, delivery: .hls, videoStreamIndex: 0, audioStreamIndex: 1)
        let args = FFmpegArgs.hls(
            media: hevcMKV, plan: plan, startSegment: 100, segmentDuration: 6,
            directory: URL(fileURLWithPath: "/tmp/out")
        )
        let joined = args.joined(separator: " ")
        // -ss must precede -i for fast input seeking.
        let ssIndex = try! #require(args.firstIndex(of: "-ss"))
        let inputIndex = try! #require(args.firstIndex(of: "-i"))
        #expect(ssIndex < inputIndex)
        #expect(joined.contains("-ss 600.000"))
        #expect(joined.contains("-output_ts_offset 600.000"))
        #expect(joined.contains("-start_number 100"))
        #expect(joined.contains("-c:a aac"))
    }
}

// MARK: - Integration (requires ffmpeg)

@Suite struct HLSSessionIntegrationTests {
    static let tools = FFTools.locate()

    /// Synthetic 8-second h264+aac clip (libx264: works everywhere, no
    /// hardware encoder needed to *generate* the fixture).
    private static func makeClip(tools: FFTools) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("castor-clip-\(UUID().uuidString).mp4")
        try await Subprocess.run(tools.ffmpeg, arguments: [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=duration=8:size=640x360:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:a", "aac", "-shortest",
            url.path,
        ])
        return url
    }

    @Test(.enabled(if: tools != nil))
    func remuxSessionProducesCompletePlaylist() async throws {
        let tools = try #require(Self.tools)
        let clip = try await Self.makeClip(tools: tools)
        defer { try? FileManager.default.removeItem(at: clip) }

        let media = try await MediaProber(tools: tools).probe(clip)
        let plan = PlayPlan(video: .copy, audio: .copy, delivery: .hls, videoStreamIndex: 0, audioStreamIndex: 1)
        let session = try HLSSession(media: media, plan: plan, tools: tools)
        try await session.start()
        defer { Task { await session.stop() } }

        #expect(await session.mode == .remux)

        // Remux-ahead completes fast; poll until ENDLIST appears.
        var playlist = ""
        for _ in 0..<50 {
            playlist = String(decoding: try await session.playlistData(), as: UTF8.self)
            if playlist.contains("#EXT-X-ENDLIST") { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        #expect(playlist.contains(".m4s"))

        let initURL = try await session.fileURL(forRequested: "init.mp4")
        #expect(FileManager.default.fileExists(atPath: initURL.path))
        let segment = try await session.fileURL(forRequested: "seg00000.m4s")
        #expect(FileManager.default.fileExists(atPath: segment.path))

        // Path traversal is rejected.
        await #expect(throws: HLSSession.SessionError.self) {
            _ = try await session.fileURL(forRequested: "../../../etc/hosts")
        }
    }
}
