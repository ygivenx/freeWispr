import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let isMicBusy: Bool

    private var menuBarImage: NSImage? {
        guard let url = Bundle.appResources.url(forResource: "MenuBarIcon", withExtension: "png", subdirectory: "Resources"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    var body: some View {
        if let nsImage = menuBarImage {
            Image(nsImage: nsImage)
                .opacity(isMicBusy ? 0.3 : isRecording ? 0.5 : 1.0)
        } else {
            Image(systemName: isMicBusy ? "mic.slash" :
                    isRecording ? "mic.fill" :
                    isTranscribing ? "text.bubble" : "mic")
        }
    }
}

public struct FreeWisprApp: App {
    @StateObject private var appState = AppState()

    public init() {
        // Prevent duplicate instances (only when running as .app with a bundle ID)
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }
        if runningApps.count > 1 {
            runningApps.first { $0 != NSRunningApplication.current }?.activate()
            DispatchQueue.main.async {
                NSApp?.terminate(nil)
            }
        }
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarIcon(isRecording: appState.isRecording, isTranscribing: appState.isTranscribing, isMicBusy: appState.isMicBusy)
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
                Picker("", selection: Binding(
                    get: { appState.selectedModel },
                    set: { newValue in
                        guard hasAppeared, !appState.isSwitchingModel else { return }
                        Task { await appState.switchModel(to: newValue) }
                    }
                )) {
                    ForEach(ModelSize.allCases) { size in
                        Text("\(size.displayName) (\(size.sizeDescription))").tag(size)
                    }
                }
                .frame(width: 160)
                .disabled(appState.isSwitchingModel)
            }

            if appState.modelManager.isDownloading {
                ProgressView(value: appState.modelManager.downloadProgress)
                    .progressViewStyle(.linear)
            }

            // AI Cleanup (macOS 26+ / Apple Intelligence)
            if appState.aiCorrectionStatus == .active {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("AI Cleanup")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("AI Cleanup", isOn: $appState.aiCorrectionEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Color(nsColor: NSColor.systemGray))
                        .labelsHidden()
                        .scaleEffect(0.8)
                }
            } else if appState.aiCorrectionStatus == .needsSetup {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text("Enable Apple Intelligence")
                            .font(.caption)
                    }
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(nsColor: NSColor.systemGray),
                                Color(nsColor: NSColor.labelColor).opacity(0.5),
                                Color(nsColor: NSColor.systemGray),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()

            if appState.updateChecker.updateAvailable,
               let latest = appState.updateChecker.latestVersion {
                if appState.updateChecker.isUpdating {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading update...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        Task { await appState.updateChecker.downloadAndInstall() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                            Text("Update to v\(latest)")
                                .foregroundColor(.green)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Divider()
            }

            HStack {
                Text("v\(appState.updateChecker.currentVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit FreeWispr") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            hasAppeared = true
        }
    }
}
