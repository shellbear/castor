import Foundation

/// What a receiver can decode and how it accepts media. Deliberately
/// conservative: a wrong "no" costs a cheap transcode, a wrong "yes" costs a
/// black screen.
public struct DeviceCapabilities: Sendable, Equatable {
    public var displayName: String
    public var supportsHEVC: Bool
    /// Codecs playable without audio transcode.
    public var audioCodecs: Set<String>
    /// Can play a progressive file over HTTP (vs. HLS only).
    public var supportsDirectFile: Bool

    public init(
        displayName: String,
        supportsHEVC: Bool,
        audioCodecs: Set<String>,
        supportsDirectFile: Bool = true
    ) {
        self.displayName = displayName
        self.supportsHEVC = supportsHEVC
        self.audioCodecs = audioCodecs
        self.supportsDirectFile = supportsDirectFile
    }

    public static let appleTV = DeviceCapabilities(
        displayName: "Apple TV",
        supportsHEVC: true,
        audioCodecs: ["aac", "mp3", "ac3", "eac3", "alac", "flac"]
    )

    /// Built from the `md` (model) field of the Chromecast mDNS TXT record.
    public static func chromecast(model: String?) -> DeviceCapabilities {
        let model = (model ?? "").lowercased()
        let hevcCapable = model.contains("ultra")
            || model.contains("google tv")
            || model.contains("streamer")
        return DeviceCapabilities(
            displayName: model.isEmpty ? "Chromecast" : model,
            supportsHEVC: hevcCapable,
            audioCodecs: ["aac", "mp3", "opus", "vorbis", "flac"]
        )
    }
}
