import Foundation

public enum MIMEType {
    public static func forPathExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "ts": "video/mp2t"
        case "m4s": "video/iso.segment"
        case "m3u8": "application/vnd.apple.mpegurl"
        case "mp3": "audio/mpeg"
        case "m4a", "aac": "audio/mp4"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "vtt": "text/vtt"
        case "srt": "application/x-subrip"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}
