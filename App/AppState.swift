import AppKit
import CastorEngine
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    struct Playback {
        var deviceName: String
        var title: String
        var state: CastClient.PlaybackSnapshot.State = .buffering
        var position: Double = 0
        var duration: Double?
        var isScrubbing = false
    }

    private enum Backend {
        case chromecast(CastClient)
        case airplay
    }

    let engineVersion = Castor.version
    let airplay = AirPlayController()

    private(set) var devices: [CastDevice] = []
    private(set) var selectedFile: URL?
    private(set) var isConnecting = false
    var playback: Playback?
    var errorMessage: String?
    var ffmpegMissing = false

    private let server = StreamServer()
    private var serverStarted = false
    private var discoveryTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var backend: Backend?
    private var hlsSession: HLSSession?

    init() {
        discoveryTask = Task { [weak self] in
            for await list in CastDiscovery.devices() {
                self?.devices = list
            }
        }
    }

    // MARK: - File selection

    func openFilePicker() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
        if let mkv = UTType(filenameExtension: "mkv") { types.append(mkv) }
        if let webm = UTType(filenameExtension: "webm") { types.append(webm) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            selectedFile = url
            errorMessage = nil
        }
    }

    // MARK: - Session setup

    func cast(to device: CastDevice) {
        guard let file = selectedFile, !isConnecting else { return }
        Task { await startCast(file: file, device: device) }
    }

    func startAirPlay() {
        guard let file = selectedFile, !isConnecting else { return }
        Task { await startAirPlaySession(file: file) }
    }

    /// Probes the file, decides direct-play vs conversion, and returns the
    /// URL + content type a receiver should load.
    private func prepareMedia(
        file: URL,
        capabilities: DeviceCapabilities
    ) async throws -> (url: URL, contentType: String, info: CastorEngine.MediaInfo)? {
        guard let tools = FFTools.locate() else {
            ffmpegMissing = true
            return nil
        }
        if !serverStarted {
            try await server.start()
            serverStarted = true
        }

        let info = try await MediaProber(tools: tools).probe(file)
        let plan = try Planner.plan(media: info, device: capabilities)

        await stopSession()

        if plan.isDirectPlay {
            let url = try await server.share(file)
            return (url, MIMEType.forPathExtension(file.pathExtension), info)
        }
        let session = try HLSSession(media: info, plan: plan, tools: tools)
        try await session.start()
        let url = try await server.register(session)
        hlsSession = session
        return (url, "application/vnd.apple.mpegurl", info)
    }

    private func startCast(file: URL, device: CastDevice) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            guard let media = try await prepareMedia(file: file, capabilities: device.capabilities) else {
                return
            }
            let client = CastClient(device: device)
            try await client.connect()

            let title = file.deletingPathExtension().lastPathComponent
            try await client.load(
                url: media.url,
                contentType: media.contentType,
                title: title,
                duration: media.info.durationSeconds
            )

            backend = .chromecast(client)
            playback = Playback(deviceName: device.name, title: title, duration: media.info.durationSeconds)
            startCastStatusUpdates(for: client)
        } catch {
            errorMessage = "Cast failed: \(error.localizedDescription)"
        }
    }

    private func startAirPlaySession(file: URL) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            guard let media = try await prepareMedia(file: file, capabilities: .appleTV) else {
                return
            }
            airplay.load(url: media.url)
            backend = .airplay
            let title = file.deletingPathExtension().lastPathComponent
            playback = Playback(
                deviceName: "AirPlay",
                title: title,
                state: .paused,
                duration: media.info.durationSeconds
            )
            startAirPlayStatusUpdates()
        } catch {
            errorMessage = "AirPlay failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Status updates

    private func startCastStatusUpdates(for client: CastClient) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let pushTask = Task { [weak self] in
                for await snapshot in await client.events() {
                    self?.apply(snapshot)
                }
            }
            defer { pushTask.cancel() }
            while !Task.isCancelled {
                if let snapshot = try? await client.status() {
                    self?.apply(snapshot)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startAirPlayStatusUpdates() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.airplay.snapshot
                if var playback = self.playback, !playback.isScrubbing {
                    playback.state = snapshot.isPlaying ? .playing : .paused
                    playback.position = snapshot.position
                    playback.deviceName = snapshot.isExternal ? "AirPlay device" : "AirPlay — pick a device"
                    self.playback = playback
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func apply(_ snapshot: CastClient.PlaybackSnapshot) {
        guard var playback, !playback.isScrubbing else { return }
        playback.state = snapshot.state
        playback.position = snapshot.position
        if let duration = snapshot.duration {
            playback.duration = duration
        }
        self.playback = playback
    }

    // MARK: - Transport controls

    func togglePlayPause() {
        guard let backend, let playback else { return }
        switch backend {
        case .chromecast(let client):
            Task {
                if playback.state == .playing {
                    try? await client.pause()
                } else {
                    try? await client.play()
                }
            }
        case .airplay:
            if playback.state == .playing {
                airplay.pause()
            } else {
                airplay.play()
            }
        }
    }

    func seek(to seconds: Double) {
        guard let backend else { return }
        switch backend {
        case .chromecast(let client):
            Task { try? await client.seek(to: seconds) }
        case .airplay:
            airplay.seek(to: seconds)
        }
    }

    func stopPlayback() {
        Task { await stopSession() }
    }

    private func stopSession() async {
        statusTask?.cancel()
        statusTask = nil
        switch backend {
        case .chromecast(let client):
            try? await client.stop()
            await client.disconnect()
        case .airplay:
            airplay.stop()
        case nil:
            break
        }
        backend = nil
        playback = nil
        if let hlsSession {
            await server.unregister(sessionId: hlsSession.id)
            await hlsSession.stop()
        }
        hlsSession = nil
        await server.unshareAll()
    }
}
