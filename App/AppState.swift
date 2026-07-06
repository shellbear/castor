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

    let engineVersion = Castor.version

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
    private var castClient: CastClient?
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

    // MARK: - Casting

    func cast(to device: CastDevice) {
        guard let file = selectedFile, !isConnecting else { return }
        Task { await startCast(file: file, device: device) }
    }

    private func startCast(file: URL, device: CastDevice) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        guard let tools = FFTools.locate() else {
            ffmpegMissing = true
            return
        }

        do {
            if !serverStarted {
                try await server.start()
                serverStarted = true
            }

            let info = try await MediaProber(tools: tools).probe(file)
            let plan = try Planner.plan(media: info, device: device.capabilities)

            await stopSession()

            let mediaURL: URL
            let contentType: String
            if plan.isDirectPlay {
                mediaURL = try await server.share(file)
                contentType = MIMEType.forPathExtension(file.pathExtension)
            } else {
                let session = try HLSSession(media: info, plan: plan, tools: tools)
                try await session.start()
                mediaURL = try await server.register(session)
                contentType = "application/vnd.apple.mpegurl"
                hlsSession = session
            }

            let client = CastClient(device: device)
            try await client.connect()

            let title = file.deletingPathExtension().lastPathComponent
            try await client.load(
                url: mediaURL,
                contentType: contentType,
                title: title,
                duration: info.durationSeconds
            )

            castClient = client
            playback = Playback(deviceName: device.name, title: title, duration: info.durationSeconds)
            startStatusUpdates(for: client)
        } catch {
            errorMessage = "Cast failed: \(error.localizedDescription)"
        }
    }

    private func startStatusUpdates(for client: CastClient) {
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
        guard let castClient, let playback else { return }
        Task {
            if playback.state == .playing {
                try? await castClient.pause()
            } else {
                try? await castClient.play()
            }
        }
    }

    func seek(to seconds: Double) {
        guard let castClient else { return }
        Task { try? await castClient.seek(to: seconds) }
    }

    func setVolume(_ level: Double) {
        guard let castClient else { return }
        Task { try? await castClient.setVolume(level) }
    }

    func stopPlayback() {
        Task { await stopSession() }
    }

    private func stopSession() async {
        statusTask?.cancel()
        statusTask = nil
        if let castClient {
            try? await castClient.stop()
            await castClient.disconnect()
        }
        castClient = nil
        playback = nil
        if let hlsSession {
            await server.unregister(sessionId: hlsSession.id)
            await hlsSession.stop()
        }
        hlsSession = nil
        await server.unshareAll()
    }
}
