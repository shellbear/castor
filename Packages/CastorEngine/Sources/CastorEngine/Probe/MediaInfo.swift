import Foundation

public struct MediaInfo: Sendable, Equatable {
    public var url: URL
    /// ffprobe `format_name`, e.g. "matroska,webm" or "mov,mp4,m4a,3gp,3g2,mj2".
    public var container: String
    public var durationSeconds: Double
    public var video: [VideoStream]
    public var audio: [AudioStream]
    public var subtitles: [SubtitleStream]

    public init(
        url: URL,
        container: String,
        durationSeconds: Double,
        video: [VideoStream],
        audio: [AudioStream],
        subtitles: [SubtitleStream]
    ) {
        self.url = url
        self.container = container
        self.durationSeconds = durationSeconds
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
    }

    public var isMP4Family: Bool {
        container.split(separator: ",").contains { $0 == "mov" || $0 == "mp4" }
    }
}

public struct VideoStream: Sendable, Equatable {
    public var index: Int
    public var codec: String
    public var profile: String?
    public var width: Int
    public var height: Int
    public var pixelFormat: String?
    public var frameRate: Double?

    public init(
        index: Int,
        codec: String,
        profile: String? = nil,
        width: Int,
        height: Int,
        pixelFormat: String? = nil,
        frameRate: Double? = nil
    ) {
        self.index = index
        self.codec = codec
        self.profile = profile
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.frameRate = frameRate
    }

    /// 10 for yuv420p10le etc., 8 otherwise.
    public var bitDepth: Int {
        guard let pixelFormat else { return 8 }
        return pixelFormat.contains("10") ? 10 : pixelFormat.contains("12") ? 12 : 8
    }
}

public struct AudioStream: Sendable, Equatable {
    public var index: Int
    public var codec: String
    public var channels: Int
    public var language: String?
    public var title: String?
    public var isDefault: Bool

    public init(
        index: Int,
        codec: String,
        channels: Int,
        language: String? = nil,
        title: String? = nil,
        isDefault: Bool = false
    ) {
        self.index = index
        self.codec = codec
        self.channels = channels
        self.language = language
        self.title = title
        self.isDefault = isDefault
    }
}

public struct SubtitleStream: Sendable, Equatable {
    public var index: Int
    public var codec: String
    public var language: String?
    public var title: String?
    public var isForced: Bool
    public var isDefault: Bool

    public init(
        index: Int,
        codec: String,
        language: String? = nil,
        title: String? = nil,
        isForced: Bool = false,
        isDefault: Bool = false
    ) {
        self.index = index
        self.codec = codec
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isDefault = isDefault
    }

    /// Text-based tracks can be converted to WebVTT; bitmap tracks (PGS,
    /// VobSub) would require burn-in.
    public var isTextBased: Bool {
        ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"].contains(codec)
    }
}
