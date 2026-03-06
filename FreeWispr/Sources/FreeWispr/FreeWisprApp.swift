import SwiftUI

@main
struct FreeWisprApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "mic.fill" :
                    appState.isTranscribing ? "text.bubble" : "mic")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                Circle()
                    .fill(appState.isRecording ? Color.red :
                            appState.isTranscribing ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(appState.statusMessage)
                    .font(.headline)
            }

            Divider()

            // Hotkey display
            HStack {
                Text("Hotkey:")
                Spacer()
                Text("⌥ Space")
                    .foregroundColor(.secondary)
            }

            // Model selector
            HStack {
                Text("Model:")
                Spacer()
                Picker("", selection: $appState.selectedModel) {
                    ForEach(ModelSize.allCases) { size in
                        Text("\(size.displayName) (\(size.sizeDescription))").tag(size)
                    }
                }
                .frame(width: 160)
                .onChange(of: appState.selectedModel) { _, newValue in
                    Task { await appState.switchModel(to: newValue) }
                }
            }

            if appState.modelManager.isDownloading {
                ProgressView(value: appState.modelManager.downloadProgress)
                    .progressViewStyle(.linear)
            }

            Divider()

            Button("Quit FreeWispr") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
        .frame(width: 280)
        .task {
            await appState.setup()
        }
    }
}
