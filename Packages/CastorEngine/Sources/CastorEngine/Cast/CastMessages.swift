import Foundation

enum CastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
}

/// The Default Media Receiver — Google's stock full-screen player app.
let defaultMediaReceiverAppID = "CC1AD845"

// MARK: - Outgoing payloads

/// Payloads that carry a requestId the receiver echoes back, enabling
/// request/response correlation on the shared socket.
protocol RequestPayload: Encodable, Sendable {
    var requestId: Int? { get set }
}

struct SimplePayload: RequestPayload {
    var type: String
    var requestId: Int?
}

struct LaunchPayload: RequestPayload {
    var type = "LAUNCH"
    var requestId: Int?
    var appId: String
}

struct SetVolumePayload: RequestPayload {
    struct Volume: Encodable {
        var level: Double?
        var muted: Bool?
    }
    var type = "SET_VOLUME"
    var requestId: Int?
    var volume: Volume
}

struct MediaCommandPayload: RequestPayload {
    var type: String
    var requestId: Int?
    var mediaSessionId: Int
    var currentTime: Double?
    var resumeState: String?
}

struct LoadPayload: RequestPayload {
    struct MediaInformation: Encodable {
        struct Metadata: Encodable {
            var metadataType = 0
            var title: String?
        }
        struct Track: Encodable {
            var trackId: Int
            var type = "TEXT"
            var subtype = "SUBTITLES"
            var trackContentId: String
            var trackContentType = "text/vtt"
            var name: String?
            var language: String?
        }
        var contentId: String
        var streamType = "BUFFERED"
        var contentType: String
        var metadata: Metadata?
        var duration: Double?
        var tracks: [Track]?
    }
    var type = "LOAD"
    var requestId: Int?
    var media: MediaInformation
    var autoplay = true
    var currentTime: Double = 0
    var activeTrackIds: [Int]?
}

// MARK: - Incoming payloads (all fields optional: decode what we can)

struct IncomingHeader: Decodable {
    var type: String?
    var requestId: Int?
}

struct ReceiverStatusPayload: Decodable {
    struct Status: Decodable {
        struct Application: Decodable {
            var appId: String?
            var sessionId: String?
            var transportId: String?
            var statusText: String?
        }
        struct Volume: Decodable {
            var level: Double?
            var muted: Bool?
        }
        var applications: [Application]?
        var volume: Volume?
    }
    var requestId: Int?
    var status: Status?
}

struct MediaStatusPayload: Decodable {
    struct Status: Decodable {
        struct Media: Decodable {
            var contentId: String?
            var duration: Double?
        }
        var mediaSessionId: Int?
        var playerState: String?
        var currentTime: Double?
        var media: Media?
    }
    var requestId: Int?
    var status: [Status]?
}
