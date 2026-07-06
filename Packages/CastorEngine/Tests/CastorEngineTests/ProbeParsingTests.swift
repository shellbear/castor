import Foundation
import Testing
@testable import CastorEngine

private func loadFixture() throws -> MediaInfo {
    let url = try #require(Bundle.module.url(
        forResource: "sample_hevc10", withExtension: "json", subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: url)
    return try MediaInfo(ffprobeJSON: data, url: URL(fileURLWithPath: "/tmp/sample_hevc10.mkv"))
}

@Suite struct ProbeParsingTests {
    @Test func parsesVideoStream() throws {
        let media = try loadFixture()
        let video = try #require(media.video.first)
        #expect(video.codec == "hevc")
        #expect(video.profile == "Main 10")
        #expect(video.width == 1920)
        #expect(video.height == 1080)
        #expect(video.bitDepth == 10)
        let fps = try #require(video.frameRate)
        #expect(abs(fps - 23.976) < 0.001)
    }

    @Test func parsesAudioTracks() throws {
        let media = try loadFixture()
        #expect(media.audio.count == 2)
        #expect(media.audio[0].language == "fre")
        #expect(media.audio[0].isDefault)
        #expect(media.audio[1].language == "jpn")
        #expect(media.audio.allSatisfy { $0.codec == "aac" && $0.channels == 6 })
    }

    @Test func parsesSubtitles() throws {
        let media = try loadFixture()
        #expect(media.subtitles.count == 2)
        #expect(media.subtitles[0].isForced)
        #expect(media.subtitles.allSatisfy { $0.codec == "ass" && $0.isTextBased })
    }

    @Test func excludesCoverArtFromVideo() throws {
        let media = try loadFixture()
        // The MKV contains an mjpeg cover-art stream that must not count as video.
        #expect(media.video.count == 1)
    }

    @Test func parsesContainerAndDuration() throws {
        let media = try loadFixture()
        #expect(media.container.contains("matroska"))
        #expect(!media.isMP4Family)
        #expect(abs(media.durationSeconds - 4907.278) < 1.0)
    }
}
