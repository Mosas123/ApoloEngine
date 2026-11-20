import SwiftUI

@main
struct RTLMetadataHarnessTVApp: App {
    var body: some Scene {
        WindowGroup {
            RTLMetadataTVView()
        }
    }
}

private struct RTLMetadataTVView: View {
    @StateObject private var model = RTLMetadataModel()
    @State private var started = false
    @State private var url = "http://10.0.0.17:8769/rtl_clean_corpus/priv_only.m3u8"

    var body: some View {
        VStack(spacing: 18) {
            Text("AVFoundation HLS metadata crash")
                .font(.title2)
            Text(model.phase)
                .font(.headline)
            TextField("HLS URL", text: $url)
                .frame(maxWidth: 900)
            Button("Run probe") {
                Task { await start() }
            }
            ScrollView {
                Text(model.messages.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 1000, maxHeight: 500)
        }
        .padding(60)
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
