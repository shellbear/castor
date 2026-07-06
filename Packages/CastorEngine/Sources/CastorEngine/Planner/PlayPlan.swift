import Foundation

/// How a given file reaches a given device.
public struct PlayPlan: Sendable, Equatable {
    public enum VideoAction: Sendable, Equatable {
        case copy
        case encodeH264
    }

    public enum AudioAction: Sendable, Equatable {
        case copy
        case encodeAAC
    }

    public enum Delivery: Sendable, Equatable {
        /// Serve the original file bytes with Range support.
        case directFile
        /// Repackage (and possibly re-encode) into fMP4 HLS.
        case hls
    }

    public var video: VideoAction
    public var audio: AudioAction
    public var delivery: Delivery
    public var videoStreamIndex: Int
    public var audioStreamIndex: Int?

    public init(
        video: VideoAction,
        audio: AudioAction,
        delivery: Delivery,
        videoStreamIndex: Int,
        audioStreamIndex: Int?
    ) {
        self.video = video
        self.audio = audio
        self.delivery = delivery
        self.videoStreamIndex = videoStreamIndex
        self.audioStreamIndex = audioStreamIndex
    }

    /// Original bytes served untouched — bit-exact quality, zero CPU.
    public var isDirectPlay: Bool {
        video == .copy && audio == .copy && delivery == .directFile
    }

    /// No video re-encode anywhere in the pipeline.
    public var preservesVideoBits: Bool {
        video == .copy
    }
}
