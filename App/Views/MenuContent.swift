import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "play.tv")
                Text("Castor")
                    .font(.headline)
                Spacer()
                Text(appState.engineVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("No devices found yet")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit Castor") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }
}
