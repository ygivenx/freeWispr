import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let isRecording: Bool
    let isTranscribing: Bool

    private var menuBarImage: NSImage? {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png", subdirectory: "Resources"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    var body: some View {
        if let nsImage = menuBarImage {
            Image(nsImage: nsImage)
                .opacity(isRecording ? 0.5 : 1.0)
        } else {
            Image(systemName: isRecording ? "mic.fill" :
                    isTranscribing ? "text.bubble" : "mic")
        }
    }
}

@main
struct FreeWisprApp: App {
    @StateObject private var appState = AppState()

    init() {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if runningApps.count > 1 {
            // Another instance is already running — activate it and quit this one
            runningApps.first { $0 != NSRunningApplication.current }?.activate()
            NSApp.terminate(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarIcon(isRecording: appState.isRecording, isTranscribing: appState.isTranscribing)
                .task {
                    await appState.setup()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var hasAppeared = false

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
                Text("🌐 Globe or ⌃⌥")
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
                    guard hasAppeared else { return }
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
        .onAppear {
            hasAppeared = true
        }
    }
}
