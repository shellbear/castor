import Foundation

/// Builds ffmpeg argument lists for the HLS pipeline. Pure and unit-tested —
/// these strings are the encoding contract of the whole app.
enum FFmpegArgs {
    /// Arguments for producing fMP4 HLS from `media` according to `plan`,
    /// starting at `startSegment` (0 = beginning; >0 = seek-restart, which
    /// offsets output timestamps so segment N really covers N×duration).
    static func hls(
        media: MediaInfo,
        plan: PlayPlan,
        startSegment: Int,
        segmentDuration: Double,
        directory: URL
    ) -> [String] {
        var args = ["-y", "-nostdin", "-hide_banner", "-loglevel", "error"]

        let transcoding = plan.video == .encodeH264
        if transcoding {
            // Hardware decode; the VideoToolbox encoder accepts the decoder
            // output directly (including 10-bit sources).
            args += ["-hwaccel", "videotoolbox"]
        }

        let startTime = Double(startSegment) * segmentDuration
        if startSegment > 0 {
            args += ["-ss", String(format: "%.3f", startTime)]
        }

        args += ["-i", media.url.path]
        args += ["-map", "0:\(plan.videoStreamIndex)"]
        if let audioIndex = plan.audioStreamIndex {
            args += ["-map", "0:\(audioIndex)"]
        }

        switch plan.video {
        case .copy:
            args += ["-c:v", "copy"]
            if media.video.first(where: { $0.index == plan.videoStreamIndex })?.codec == "hevc" {
                // Apple players reject hev1-tagged HEVC in fMP4.
                args += ["-tag:v", "hvc1"]
            }
        case .encodeH264:
            args += [
                "-c:v", "h264_videotoolbox",
                "-b:v", "12M",
                "-profile:v", "high",
                // Deterministic keyframes = deterministic segment boundaries,
                // which the predicted VOD playlist depends on.
                "-force_key_frames", "expr:gte(t,n_forced*\(Int(segmentDuration)))",
            ]
        }

        switch plan.audio {
        case .copy:
            args += ["-c:a", "copy"]
        case .encodeAAC:
            args += ["-c:a", "aac", "-b:a", "256k"]
        }

        if startSegment > 0 {
            args += ["-output_ts_offset", String(format: "%.3f", startTime)]
        }

        args += [
            "-f", "hls",
            "-hls_time", String(Int(segmentDuration)),
            "-hls_playlist_type", "vod",
            "-hls_segment_type", "fmp4",
            // Segments appear atomically: written as .tmp, then renamed.
            "-hls_flags", "temp_file",
            "-hls_fmp4_init_filename", "init.mp4",
            "-start_number", String(startSegment),
            "-hls_segment_filename", directory.appendingPathComponent("seg%05d.m4s").path,
            directory.appendingPathComponent("index.m3u8").path,
        ]
        return args
    }
}
