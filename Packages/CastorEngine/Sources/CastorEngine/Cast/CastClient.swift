import Foundation

/// High-level Chromecast session: launches the Default Media Receiver, loads
/// a URL, and exposes transport controls plus status updates.
public actor CastClient {
    public enum CastError: Error {
        case appLaunchFailed
        case loadFailed
        case noActiveSession
    }

    public struct PlaybackSnapshot: Sendable, Equatable {
        public enum State: String, Sendable {
            case idle = "IDLE"
            case buffering = "BUFFERING"
            case playing = "PLAYING"
            case paused = "PAUSED"
        }
        public var state: State
        public var position: Double
        public var duration: Double?
    }

    public struct SubtitleTrack: Sendable {
        public var id: Int
        public var url: URL
        public var name: String?
        public var language: String?

        public init(id: Int, url: URL, name: String? = nil, language: String? = nil) {
            self.id = id
            self.url = url
            self.name = name
            self.language = language
        }
    }

    public let device: CastDevice
    private var channel: CastChannel?
    private var transportId: String?
    private var mediaSessionId: Int?

    public init(device: CastDevice) {
        self.device = device
    }

    // MARK: - Session

    public func connect() async throws {
        guard channel == nil else { return }
        let channel = CastChannel(endpoint: device.endpoint)
        try await channel.connect()
        self.channel = channel
    }

    public func disconnect() async {
        await channel?.close()
        channel = nil
        transportId = nil
        mediaSessionId = nil
    }

    /// Launches the receiver app and loads the media URL.
    public func load(
        url: URL,
        contentType: String,
        title: String? = nil,
        duration: Double? = nil,
        startTime: Double = 0,
        subtitles: [SubtitleTrack] = [],
        activeSubtitleId: Int? = nil
    ) async throws {
        guard let channel else { throw CastError.noActiveSession }

        let transport = try await launchDefaultReceiver(on: channel)
        transportId = transport
        try await channel.send(
            namespace: CastNamespace.connection,
            destination: transport,
            payload: SimplePayload(type: "CONNECT")
        )

        let tracks = subtitles.map { track in
            LoadPayload.MediaInformation.Track(
                trackId: track.id,
                trackContentId: track.url.absoluteString,
                name: track.name,
                language: track.language
            )
        }
        let load = LoadPayload(
            media: .init(
                contentId: url.absoluteString,
                contentType: contentType,
                metadata: title.map { .init(title: $0) },
                duration: duration,
                tracks: tracks.isEmpty ? nil : tracks
            ),
            currentTime: startTime,
            activeTrackIds: activeSubtitleId.map { [$0] }
        )
        let status = try await channel.request(
            namespace: CastNamespace.media,
            destination: transport,
            payload: load,
            as: MediaStatusPayload.self,
            timeout: .seconds(20)
        )
        guard let sessionId = status.status?.first?.mediaSessionId else {
            throw CastError.loadFailed
        }
        mediaSessionId = sessionId
    }

    private func launchDefaultReceiver(on channel: CastChannel) async throws -> String {
        let response = try await channel.request(
            namespace: CastNamespace.receiver,
            destination: "receiver-0",
            payload: LaunchPayload(appId: defaultMediaReceiverAppID),
            as: ReceiverStatusPayload.self,
            timeout: .seconds(15)
        )
        if let transport = Self.transportId(in: response) {
            return transport
        }
        // The receiver may report the app before it finishes launching.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(600))
            let status = try await channel.request(
                namespace: CastNamespace.receiver,
                destination: "receiver-0",
                payload: SimplePayload(type: "GET_STATUS"),
                as: ReceiverStatusPayload.self
            )
            if let transport = Self.transportId(in: status) {
                return transport
            }
        }
        throw CastError.appLaunchFailed
    }

    private static func transportId(in status: ReceiverStatusPayload) -> String? {
        status.status?.applications?
            .first { $0.appId == defaultMediaReceiverAppID }?
            .transportId
    }

    // MARK: - Transport controls

    public func play() async throws { try await sendMediaCommand("PLAY") }
    public func pause() async throws { try await sendMediaCommand("PAUSE") }
    public func stop() async throws { try await sendMediaCommand("STOP") }

    public func seek(to seconds: Double) async throws {
        guard let channel, let transportId, let mediaSessionId else { throw CastError.noActiveSession }
        _ = try await channel.request(
            namespace: CastNamespace.media,
            destination: transportId,
            payload: MediaCommandPayload(
                type: "SEEK",
                mediaSessionId: mediaSessionId,
                currentTime: seconds,
                resumeState: "PLAYBACK_START"
            ),
            as: MediaStatusPayload.self
        )
    }

    public func setVolume(_ level: Double) async throws {
        guard let channel else { throw CastError.noActiveSession }
        _ = try await channel.request(
            namespace: CastNamespace.receiver,
            destination: "receiver-0",
            payload: SetVolumePayload(volume: .init(level: min(max(level, 0), 1), muted: nil)),
            as: ReceiverStatusPayload.self
        )
    }

    private func sendMediaCommand(_ type: String) async throws {
        guard let channel, let transportId, let mediaSessionId else { throw CastError.noActiveSession }
        _ = try await channel.request(
            namespace: CastNamespace.media,
            destination: transportId,
            payload: MediaCommandPayload(type: type, mediaSessionId: mediaSessionId),
            as: MediaStatusPayload.self
        )
    }

    // MARK: - Status

    public func status() async throws -> PlaybackSnapshot? {
        guard let channel, let transportId else { throw CastError.noActiveSession }
        let payload = try await channel.request(
            namespace: CastNamespace.media,
            destination: transportId,
            payload: SimplePayload(type: "GET_STATUS"),
            as: MediaStatusPayload.self
        )
        return Self.snapshot(from: payload)
    }

    /// Unsolicited MEDIA_STATUS pushes (state changes, track changes…).
    public func events() async -> AsyncStream<PlaybackSnapshot> {
        guard let channel else {
            return AsyncStream { $0.finish() }
        }
        let envelopes = await channel.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await envelope in envelopes {
                    guard envelope.namespace == CastNamespace.media,
                          let payload = try? JSONDecoder().decode(MediaStatusPayload.self, from: envelope.payload),
                          let snapshot = Self.snapshot(from: payload)
                    else { continue }
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func snapshot(from payload: MediaStatusPayload) -> PlaybackSnapshot? {
        guard let status = payload.status?.first else { return nil }
        return PlaybackSnapshot(
            state: status.playerState.flatMap(PlaybackSnapshot.State.init(rawValue:)) ?? .idle,
            position: status.currentTime ?? 0,
            duration: status.media?.duration
        )
    }
}
