import Foundation
import SwiftUI

struct RTLMetadataView: View {
    @StateObject private var model = RTLMetadataModel()
    @State private var metadataMode: MetadataProbeMode = .disabled
    @State private var playerKind: ProbePlayerKind = .queue
    @State private var reloadMode: ProbeReloadMode = .once
    @State private var acceptCrashRisk = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    Text("RTL France · Radio Browser UUID")
                        .font(.headline)
                    Text(RTLMetadataModel.rtlUUID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    TextField("Optional exact .m3u8 URL override", text: $model.urlOverride)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("If no URL is entered, resolve RTL via the public Radio Browser API. Never share signed stream URLs in logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Independent variables") {
                    Picker("Metadata observer", selection: $metadataMode) {
                        ForEach(MetadataProbeMode.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Picker("AVFoundation player", selection: $playerKind) {
                        ForEach(ProbePlayerKind.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Picker("Load sequence", selection: $reloadMode) {
                        ForEach(ProbeReloadMode.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
                Section("Safety") {
                    if metadataMode.installsOutput {
                        Label("Experimental metadata output may crash iOS app", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Toggle("I accept that this separate test app may crash", isOn: $acceptCrashRisk)
                    } else {
                        Text("SAFE BASELINE: AVPlayerItemMetadataOutput is not installed.")
                            .foregroundStyle(.green)
                    }
                    Text("This experiment has no ApoloEngine, Thrum, FFmpeg or MPVKit dependency. Playback ends automatically after 180 seconds. Only run unsafe variants when explicitly testing.")
                        .font(.caption)
                }
                Section("Run") {
                    Button("Start RTL experiment") {
                        Task {
                            await model.start(
                                metadataMode: metadataMode,
                                playerKind: playerKind,
                                reloadMode: reloadMode
                            )
                        }
                    }
                    .disabled(model.isRunning || (metadataMode.installsOutput && !acceptCrashRisk))
                    Button("Stop and release item") {
                        model.stop()
                    }
                    .disabled(!model.isRunning)
                    Text("State: \(model.phase)")
                        .font(.footnote.monospaced())
                    ShareLink(item: model.logURL) {
                        Label("Export persistent crash-proof event log", systemImage: "square.and.arrow.up")
                    }
                }
                Section("Recent events (latest at bottom)") {
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("RTL HLS Repro")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await autoStartIfRequested() }
    }

    @MainActor
    private func autoStartIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-autoStart") else { return }
        if let i = args.firstIndex(of: "-probeURL"), i + 1 < args.count {
            model.urlOverride = args[i + 1]
        }
        metadataMode = .titleID3Only
        acceptCrashRisk = true
        await model.start(metadataMode: metadataMode, playerKind: playerKind, reloadMode: reloadMode)
    }
}
