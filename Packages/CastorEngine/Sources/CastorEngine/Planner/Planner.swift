import Foundation

/// The decision engine: touch as little as possible, in this order —
/// direct play (serve bytes) → remux (repackage) → transcode (re-encode).
public enum Planner {
    public struct Options: Sendable {
        public var forceTranscode: Bool
        public var preferredAudioStreamIndex: Int?

        public init(forceTranscode: Bool = false, preferredAudioStreamIndex: Int? = nil) {
            self.forceTranscode = forceTranscode
            self.preferredAudioStreamIndex = preferredAudioStreamIndex
        }
    }

    public enum PlanError: Error, Equatable {
        case noVideoStream
    }

    public static func plan(
        media: MediaInfo,
        device: DeviceCapabilities,
        options: Options = Options()
    ) throws -> PlayPlan {
        guard let video = media.video.first else {
            throw PlanError.noVideoStream
        }

        let audio = selectAudio(from: media, preferred: options.preferredAudioStreamIndex)

        let videoCompatible = isVideoCompatible(video, device: device)
        let audioCompatible = audio.map { device.audioCodecs.contains($0.codec) } ?? true

        let videoAction: PlayPlan.VideoAction =
            (videoCompatible && !options.forceTranscode) ? .copy : .encodeH264
        let audioAction: PlayPlan.AudioAction = audioCompatible ? .copy : .encodeAAC

        // Direct play needs a fully compatible file in an MP4-family container
        // and a device that accepts progressive files.
        let delivery: PlayPlan.Delivery =
            (videoAction == .copy && audioAction == .copy
                && media.isMP4Family && device.supportsDirectFile)
            ? .directFile : .hls

        return PlayPlan(
            video: videoAction,
            audio: audioAction,
            delivery: delivery,
            videoStreamIndex: video.index,
            audioStreamIndex: audio?.index
        )
    }

    private static func selectAudio(from media: MediaInfo, preferred: Int?) -> AudioStream? {
        if let preferred, let match = media.audio.first(where: { $0.index == preferred }) {
            return match
        }
        return media.audio.first(where: \.isDefault) ?? media.audio.first
    }

    private static func isVideoCompatible(_ video: VideoStream, device: DeviceCapabilities) -> Bool {
        switch video.codec {
        case "h264":
            // 10-bit H.264 has no hardware decoder on any receiver.
            return video.bitDepth == 8
        case "hevc":
            return device.supportsHEVC
        default:
            return false
        }
    }
}
