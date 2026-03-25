import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let isRecording: Bool
    let isTranscribing: Bool

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
                .opacity(isRecording ? 0.5 : 1.0)
        } else {
            Image(systemName: isRecording ? "mic.fill" :
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

    /// Maps status message to dot color: red = recording/error, orange = warning, blue = processing, green = ready.
    private var statusDotColor: Color {
        let msg = appState.statusMessage
        if appState.isRecording { return .red }
        if appState.isTranscribing { return .blue }
        if msg.contains("failed") || msg.contains("error") || msg.contains("Failed") { return .red }
        if msg.contains("timed out") || msg.contains("Too quiet") || msg.contains("Didn't catch")
            || msg.contains("Mic busy") { return .orange }
        if msg.starts(with: "Downloading") || msg.starts(with: "Correcting") { return .blue }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Text(appState.statusMessage)
                    .font(.headline)
                    .accessibilityLabel(appState.statusMessage)
            }
            .accessibilityElement(children: .combine)

            Divider()

            // Hotkey display
            HStack {
                Text("Push to Talk:")
                Spacer()
                Text("🌐 Globe or ⌃⌥")
                    .foregroundColor(.secondary)
            }

            // Model selector
            VStack(alignment: .leading, spacing: 2) {
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
                Text("Larger models improve accuracy; base works for most English")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
                    Text("Auto-correct")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Auto-correct", isOn: $appState.aiCorrectionEnabled)
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
        .onChange(of: appState.statusMessage) { _, newValue in
            // Announce errors and warnings to VoiceOver
            if newValue.contains("failed") || newValue.contains("timed out")
                || newValue.contains("Too quiet") || newValue.contains("Didn't catch")
                || newValue.contains("Mic busy") || newValue.contains("error") {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: newValue, .priority: NSAccessibilityPriorityLevel.high])
            }
        }
    }
}
