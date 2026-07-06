import Foundation

/// Raw ffprobe `-print_format json` document.
struct FFProbeDocument: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_name: String?
        let codec_type: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let r_frame_rate: String?
        let channels: Int?
        let disposition: [String: Int]?
        let tags: [String: String]?
    }

    struct Format: Decodable {
        let format_name: String?
        let duration: String?
    }

    let streams: [Stream]
    let format: Format?
}

extension MediaInfo {
    /// Codecs that are cover art / thumbnails rather than playable video.
    private static let attachedPictureCodecs: Set<String> = ["mjpeg", "png", "bmp", "gif"]

    public init(ffprobeJSON data: Data, url: URL) throws {
        let doc = try JSONDecoder().decode(FFProbeDocument.self, from: data)

        var video: [VideoStream] = []
        var audio: [AudioStream] = []
        var subtitles: [SubtitleStream] = []

        for stream in doc.streams {
            let disposition = stream.disposition ?? [:]
            let tags = stream.tags ?? [:]
            switch stream.codec_type {
            case "video":
                guard let codec = stream.codec_name,
                      disposition["attached_pic"] != 1,
                      !Self.attachedPictureCodecs.contains(codec)
                else { continue }
                video.append(VideoStream(
                    index: stream.index,
                    codec: codec,
                    profile: stream.profile,
                    width: stream.width ?? 0,
                    height: stream.height ?? 0,
                    pixelFormat: stream.pix_fmt,
                    frameRate: Self.parseFraction(stream.r_frame_rate)
                ))
            case "audio":
                guard let codec = stream.codec_name else { continue }
                audio.append(AudioStream(
                    index: stream.index,
                    codec: codec,
                    channels: stream.channels ?? 2,
                    language: tags["language"],
                    title: tags["title"],
                    isDefault: disposition["default"] == 1
                ))
            case "subtitle":
                guard let codec = stream.codec_name else { continue }
                subtitles.append(SubtitleStream(
                    index: stream.index,
                    codec: codec,
                    language: tags["language"],
                    title: tags["title"],
                    isForced: disposition["forced"] == 1,
                    isDefault: disposition["default"] == 1
                ))
            default:
                continue
            }
        }

        self.init(
            url: url,
            container: doc.format?.format_name ?? "",
            durationSeconds: doc.format?.duration.flatMap(Double.init) ?? 0,
            video: video,
            audio: audio,
            subtitles: subtitles
        )
    }

    /// "24000/1001" → 23.976…
    static func parseFraction(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
            return num / den
        }
        return Double(text)
    }
}
