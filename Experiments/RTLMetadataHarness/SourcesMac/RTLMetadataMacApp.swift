import SwiftUI

@main
struct RTLMetadataHarnessMacApp: App {
    var body: some Scene {
        WindowGroup {
            RTLMetadataMacView()
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

private struct RTLMetadataMacView: View {
    @StateObject private var model = RTLMetadataModel()
    @State private var started = false
    @State private var url = "http://10.0.0.17:8769/rtl_clean_corpus/priv_only.m3u8"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AVFoundation HLS metadata crash")
                .font(.title2)
            Text(model.phase)
                .font(.headline)
            TextField("HLS URL", text: $url)
            HStack {
                Button("Run probe") {
                    Task { await start() }
                }
                Button("Stop") { model.stop() }
            }
            ScrollView {
                Text(model.messages.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .task {
            guard !started else { return }
            started = true
            await start()
        }
    }

    @MainActor
    private func start() async {
        model.urlOverride = url
        await model.start(metadataMode: .titleID3Only, playerKind: .queue, reloadMode: .once)
    }
}
