import Foundation
import Testing
@testable import CastorEngine

private func media(
    container: String,
    videoCodec: String,
    pixelFormat: String = "yuv420p",
    audioCodec: String = "aac"
) -> MediaInfo {
    MediaInfo(
        url: URL(fileURLWithPath: "/tmp/test.file"),
        container: container,
        durationSeconds: 5400,
        video: [VideoStream(index: 0, codec: videoCodec, width: 1920, height: 1080, pixelFormat: pixelFormat)],
        audio: [AudioStream(index: 1, codec: audioCodec, channels: 6, isDefault: true)],
        subtitles: []
    )
}

private let hevc10MKV = media(container: "matroska,webm", videoCodec: "hevc", pixelFormat: "yuv420p10le")
private let h264MP4 = media(container: "mov,mp4,m4a,3gp,3g2,mj2", videoCodec: "h264")
private let oldChromecast = DeviceCapabilities.chromecast(model: "Chromecast")
private let googleTV = DeviceCapabilities.chromecast(model: "Chromecast with Google TV")

@Suite struct PlannerTests {
    @Test func compatibleMP4DirectPlaysEverywhere() throws {
        for device in [DeviceCapabilities.appleTV, oldChromecast, googleTV] {
            let plan = try Planner.plan(media: h264MP4, device: device)
            #expect(plan.isDirectPlay, "expected direct play on \(device.displayName)")
        }
    }

    @Test func hevc10MKVRemuxesToAppleTV() throws {
        let plan = try Planner.plan(media: hevc10MKV, device: .appleTV)
        #expect(plan.video == .copy)
        #expect(plan.audio == .copy)
        #expect(plan.delivery == .hls)
        #expect(plan.preservesVideoBits)
    }

    @Test func hevc10MKVTranscodesToOldChromecast() throws {
        let plan = try Planner.plan(media: hevc10MKV, device: oldChromecast)
        #expect(plan.video == .encodeH264)
        #expect(plan.audio == .copy)
        #expect(plan.delivery == .hls)
    }

    @Test func hevcRemuxesToHEVCCapableChromecast() throws {
        let plan = try Planner.plan(media: hevc10MKV, device: googleTV)
        #expect(plan.video == .copy)
        #expect(plan.delivery == .hls)
    }

    @Test func tenBitH264AlwaysTranscodes() throws {
        let anime = media(container: "matroska,webm", videoCodec: "h264", pixelFormat: "yuv420p10le")
        let plan = try Planner.plan(media: anime, device: .appleTV)
        #expect(plan.video == .encodeH264)
    }

    @Test func dtsAudioTranscodesVideoCopies() throws {
        let dtsMKV = media(container: "matroska,webm", videoCodec: "h264", audioCodec: "dts")
        let plan = try Planner.plan(media: dtsMKV, device: .appleTV)
        #expect(plan.video == .copy)
        #expect(plan.audio == .encodeAAC)
        #expect(plan.delivery == .hls)
    }

    @Test func ac3PassesToAppleTVNotChromecast() throws {
        let ac3MP4 = media(container: "mov,mp4,m4a,3gp,3g2,mj2", videoCodec: "h264", audioCodec: "ac3")
        #expect(try Planner.plan(media: ac3MP4, device: .appleTV).isDirectPlay)
        #expect(try Planner.plan(media: ac3MP4, device: oldChromecast).audio == .encodeAAC)
    }

    @Test func forceTranscodeOverridesCopy() throws {
        let plan = try Planner.plan(
            media: h264MP4, device: .appleTV,
            options: .init(forceTranscode: true)
        )
        #expect(plan.video == .encodeH264)
        #expect(plan.delivery == .hls)
    }

    @Test func audiolessMediaThrowsNoError() throws {
        var silent = h264MP4
        silent.audio = []
        let plan = try Planner.plan(media: silent, device: .appleTV)
        #expect(plan.audioStreamIndex == nil)
        #expect(plan.isDirectPlay)
    }

    @Test func noVideoStreamThrows() {
        var broken = h264MP4
        broken.video = []
        #expect(throws: Planner.PlanError.noVideoStream) {
            try Planner.plan(media: broken, device: .appleTV)
        }
    }
}
