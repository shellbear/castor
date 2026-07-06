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
    private(set) var selectedMediaInfo: CastorEngine.MediaInfo?
    private(set) var isConnecting = false
    private(set) var continueWatching: [HistoryEntry] = []
    var selectedSubtitleIndex: Int?
    var playback: Playback?
    var errorMessage: String?
    var ffmpegMissing = false

    var forceTranscode: Bool = UserDefaults.standard.bool(forKey: "forceTranscode") {
        didSet { UserDefaults.standard.set(forceTranscode, forKey: "forceTranscode") }
    }

    private let server = StreamServer()
    private let history = HistoryStore()
    private var serverStarted = false
    private var discoveryTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var backend: Backend?
    private var hlsSession: HLSSession?
    private var activeFile: URL?
    private var lastSavedPosition: Double = .infinity

    init() {
        discoveryTask = Task { [weak self] in
            for await list in CastDiscovery.devices() {
                self?.devices = list
            }
        }
        Task { await refreshHistory() }
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
            selectFile(url)
        }
    }

    func selectFile(_ url: URL) {
        selectedFile = url
        selectedMediaInfo = nil
        selectedSubtitleIndex = nil
        errorMessage = nil
        Task { await probeSelection(url) }
    }

    private func probeSelection(_ url: URL) async {
        guard let tools = FFTools.locate() else {
            ffmpegMissing = true
            return
        }
        guard let info = try? await MediaProber(tools: tools).probe(url),
              selectedFile == url
        else { return }
        selectedMediaInfo = info
        let audioLanguage = info.audio.first(where: \.isDefault)?.language ?? info.audio.first?.language
        selectedSubtitleIndex = SubtitleExtractor
            .defaultTrack(in: info, audioLanguage: audioLanguage)?.index
    }

    // MARK: - History

    func resume(_ entry: HistoryEntry) {
        let url = URL(fileURLWithPath: entry.path)
        guard FileManager.default.fileExists(atPath: entry.path) else {
            errorMessage = "File no longer exists: \(entry.title)"
            Task {
                await history.remove(path: entry.path)
                await refreshHistory()
            }
            return
        }
        selectFile(url)
        if let deviceName = entry.deviceName,
           let device = devices.first(where: { $0.name == deviceName }) {
            cast(to: device)
        }
    }

    private func refreshHistory() async {
        continueWatching = Array(await history.all().filter(\.isResumable).prefix(4))
    }

    private func persistProgress(position: Double) {
        guard let activeFile, let playback,
              abs(position - lastSavedPosition) >= 5
        else { return }
        lastSavedPosition = position
        let title = playback.title
        let duration = playback.duration ?? 0
        let deviceName = playback.deviceName
        Task {
            await history.update(
                path: activeFile.path,
                title: title,
                position: position,
                duration: duration,
                deviceName: deviceName
            )
            await refreshHistory()
        }
    }

    // MARK: - URL scheme (castor://)

    func handle(url: URL) {
        guard url.scheme == "castor" else { return }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        switch url.host {
        case "cast":
            guard let path = query("path") else { return }
            let file = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                errorMessage = "File not found: \(path)"
                return
            }
            selectFile(file)
            if let wanted = query("device")?.lowercased(),
               let device = devices.first(where: {
                   $0.name.lowercased() == wanted || $0.id.lowercased() == wanted
               }) {
                cast(to: device)
            }
        case "toggle":
            togglePlayPause()
        case "stop":
            stopPlayback()
        case "resume-last":
            Task {
                guard let entry = await history.all().first(where: \.isResumable) else { return }
                resume(entry)
            }
        default:
            break
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
        capabilities: DeviceCapabilities,
        tools: FFTools
    ) async throws -> (url: URL, contentType: String, info: CastorEngine.MediaInfo) {
        if !serverStarted {
            try await server.start()
            serverStarted = true
        }

        let info: CastorEngine.MediaInfo
        if let selectedMediaInfo, selectedMediaInfo.url == file {
            info = selectedMediaInfo
        } else {
            info = try await MediaProber(tools: tools).probe(file)
        }
        let plan = try Planner.plan(
            media: info,
            device: capabilities,
            options: .init(forceTranscode: forceTranscode)
        )

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

    private func resumePosition(for file: URL) async -> Double {
        guard let entry = await history.entry(forPath: file.path), entry.isResumable else {
            return 0
        }
        return entry.position
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
            let media = try await prepareMedia(file: file, capabilities: device.capabilities, tools: tools)

            // Side-load the selected text subtitle as WebVTT.
            var subtitleTracks: [CastClient.SubtitleTrack] = []
            if let subtitleIndex = selectedSubtitleIndex,
               let subtitle = media.info.subtitles.first(where: { $0.index == subtitleIndex }),
               subtitle.isTextBased {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("castor-subs", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let vtt = try? await SubtitleExtractor(tools: tools)
                    .extractVTT(from: media.info, streamIndex: subtitleIndex, into: directory),
                   let vttURL = try? await server.share(vtt) {
                    subtitleTracks = [
                        .init(id: subtitleIndex, url: vttURL, name: subtitle.title, language: subtitle.language)
                    ]
                }
            }

            let client = CastClient(device: device)
            try await client.connect()

            let title = file.deletingPathExtension().lastPathComponent
            let startTime = await resumePosition(for: file)
            try await client.load(
                url: media.url,
                contentType: media.contentType,
                title: title,
                duration: media.info.durationSeconds,
                startTime: startTime,
                subtitles: subtitleTracks,
                activeSubtitleId: subtitleTracks.first?.id
            )

            backend = .chromecast(client)
            activeFile = file
            lastSavedPosition = .infinity
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

        guard let tools = FFTools.locate() else {
            ffmpegMissing = true
            return
        }

        do {
            let media = try await prepareMedia(file: file, capabilities: .appleTV, tools: tools)
            let startTime = await resumePosition(for: file)
            airplay.load(url: media.url, startTime: startTime)
            backend = .airplay
            activeFile = file
            lastSavedPosition = .infinity
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
                    if snapshot.isPlaying {
                        self.persistProgress(position: snapshot.position)
                    }
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
        if snapshot.state == .playing {
            persistProgress(position: snapshot.position)
        }
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
        // Final position save so quitting mid-film resumes precisely.
        if let activeFile, let playback, playback.position > 0 {
            let position = playback.position
            let title = playback.title
            let duration = playback.duration ?? 0
            let deviceName = playback.deviceName
            await history.update(
                path: activeFile.path,
                title: title,
                position: position,
                duration: duration,
                deviceName: deviceName
            )
            await refreshHistory()
        }
        activeFile = nil
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
