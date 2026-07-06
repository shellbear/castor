import Foundation

/// Generates the predicted VOD playlist for transcode sessions: every segment
/// is listed up front (total duration is known from probing), so the receiver
/// shows a full seek bar immediately — segments are produced on demand.
enum HLSPlaylist {
    static func vod(duration: Double, segmentDuration: Double) -> String {
        let fullSegments = Int(duration / segmentDuration)
        let remainder = duration - Double(fullSegments) * segmentDuration

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(segmentDuration))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for index in 0..<fullSegments {
            lines.append(String(format: "#EXTINF:%.6f,", segmentDuration))
            lines.append(segmentName(index))
        }
        if remainder > 0.01 {
            lines.append(String(format: "#EXTINF:%.6f,", remainder))
            lines.append(segmentName(fullSegments))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func segmentName(_ index: Int) -> String {
        String(format: "seg%05d.m4s", index)
    }

    /// "seg00042.m4s" → 42
    static func segmentNumber(fromName name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    static func segmentCount(duration: Double, segmentDuration: Double) -> Int {
        let fullSegments = Int(duration / segmentDuration)
        let remainder = duration - Double(fullSegments) * segmentDuration
        return fullSegments + (remainder > 0.01 ? 1 : 0)
    }
}
