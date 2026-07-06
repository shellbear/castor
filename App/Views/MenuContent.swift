import CastorEngine
import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if appState.playback != nil {
                NowPlayingView()
                Divider()
            }

            fileSection
            Divider()
            deviceSection

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if appState.ffmpegMissing {
                Text("ffmpeg not found — install it with `brew install ffmpeg`.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            Button("Quit Castor") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "play.tv")
            Text("Castor").font(.headline)
            Spacer()
            Text(appState.engineVersion)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var fileSection: some View {
        HStack {
            if let file = appState.selectedFile {
                Image(systemName: "film")
                Text(file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { appState.openFilePicker() }
                    .controlSize(.small)
            } else {
                Button {
                    appState.openFilePicker()
                } label: {
                    Label("Open Video…", systemImage: "folder")
                }
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.devices.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching your network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(appState.devices) { device in
                    Button {
                        appState.cast(to: device)
                    } label: {
                        HStack {
                            Image(systemName: "tv")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                if let model = device.model {
                                    Text(model)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.selectedFile == nil || appState.isConnecting)
                }
                if appState.selectedFile == nil {
                    Text("Open a video to enable casting.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    appState.startAirPlay()
                } label: {
                    HStack {
                        Image(systemName: "airplay.video")
                        Text("Stream via AirPlay")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.selectedFile == nil || appState.isConnecting)

                RoutePickerView(player: appState.airplay.player)
                    .frame(width: 22, height: 22)
            }

            if appState.isConnecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption)
                }
            }
        }
    }
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        if let playback = appState.playback {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playback.title).lineLimit(1).truncationMode(.middle)
                        Text(playback.deviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let duration = playback.duration, duration > 0 {
                    Slider(
                        value: Binding(
                            get: { playback.position },
                            set: { appState.playback?.position = $0 }
                        ),
                        in: 0...duration
                    ) { editing in
                        appState.playback?.isScrubbing = editing
                        if !editing {
                            appState.seek(to: appState.playback?.position ?? 0)
                        }
                    }
                    HStack {
                        Text(Self.timestamp(playback.position))
                        Spacer()
                        Text(Self.timestamp(duration))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Button {
                        appState.togglePlayPause()
                    } label: {
                        Image(systemName: playback.state == .playing ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.stopPlayback()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if playback.state == .buffering {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
