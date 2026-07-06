import AVFoundation
import Foundation

/// AirPlay via AVPlayer external playback: when the user routes to an Apple
/// TV, the device fetches our server URL directly — full quality, no
/// mirroring. Playback stays paused locally until an external route is
/// active, so nothing plays out of the Mac's speakers meanwhile.
@MainActor
public final class AirPlayController {
    public struct Snapshot: Sendable, Equatable {
        public var isPlaying: Bool
        public var isExternal: Bool
        public var position: Double
    }

    public let player = AVPlayer()
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var autoplayWhenExternal = false

    public init() {
        player.allowsExternalPlayback = true
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.externalPlaybackChanged()
            }
        }
    }

    public func load(url: URL, startTime: Double = 0) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if startTime > 0 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }
        // Wait for the user to pick a route; start on the TV, not the Mac.
        autoplayWhenExternal = true
        if player.isExternalPlaybackActive {
            player.play()
        }
    }

    public func play() {
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .positiveInfinity
        )
    }

    public func stop() {
        autoplayWhenExternal = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    public var snapshot: Snapshot {
        Snapshot(
            isPlaying: player.rate > 0,
            isExternal: player.isExternalPlaybackActive,
            position: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        )
    }

    private func externalPlaybackChanged() {
        if player.isExternalPlaybackActive, autoplayWhenExternal, player.currentItem != nil {
            player.play()
        }
    }
}
