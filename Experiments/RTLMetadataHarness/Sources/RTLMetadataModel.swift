import AVFoundation
import Foundation
import SwiftUI

enum MetadataProbeMode: String, CaseIterable, Identifiable {
    case disabled = "OFF · audio-only baseline"
    case titleMain = "Title IDs · main queue"
    case titleSerial = "Title IDs · serial queue"
    case allMain = "All IDs · main queue"

    var id: String { rawValue }
    var installsOutput: Bool { self != .disabled }

    var identifiers: [String]? {
        switch self {
        case .disabled:
            return []
        case .titleMain, .titleSerial:
            // The exact two identifiers used by ApoloEngine's unsafe PR #12.
            return [
                AVMetadataIdentifier.id3MetadataTitleDescription.rawValue,
                AVMetadataIdentifier.commonIdentifierTitle.rawValue
            ]
        case .allMain:
            return nil
        }
    }
}

enum ProbePlayerKind: String, CaseIterable, Identifiable {
    case queue = "AVQueuePlayer (same as Apolo)"
    case standard = "AVPlayer"
    var id: String { rawValue }
}

enum ProbeReloadMode: String, CaseIterable, Identifiable {
    case once = "One load"
    case twice = "Reload once after 1.231 s"
    var id: String { rawValue }
}

/// This object deliberately has no dependency on ApoloEngine or Thrum.
/// AVFoundation metadata delegate is weak: the model strongly retains this sink.
private final class TimedMetadataSink: NSObject,
    AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
    private let report: @Sendable (Int, Bool) -> Void

    init(report: @escaping @Sendable (Int, Bool) -> Void) {
        self.report = report
    }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: sending [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        // Match ApoloEngine's title-filter traversal without retaining AV objects.
        let hasTitle = groups.contains { group in
            group.items.reversed().contains { item in
                guard item.identifier == .id3MetadataTitleDescription
                    || item.identifier == .commonIdentifierTitle
                    || item.commonKey == .commonKeyTitle else {
                    return false
                }
                return !(item.stringValue ?? "").isEmpty
            }
        }
        report(groups.count, hasTitle)
    }
}

private struct RadioBrowserStation: Decodable {
    let url: String?
    let url_resolved: String?
}

@MainActor
final class RTLMetadataModel: ObservableObject {
    static let rtlUUID = "042d3140-227c-4fac-9387-4903b692d5f2"

    @Published private(set) var messages: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var phase = "Idle"
    @Published var urlOverride = UserDefaults.standard.string(forKey: "rtlHarness.urlOverride") ?? ""

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var metadataSink: TimedMetadataSink?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var automaticReload: Task<Void, Never>?
    private var autoStop: Task<Void, Never>?
    private var runID: UInt64 = 0
    private var itemGeneration: UInt64 = 0

    let logURL: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("rtl-hls-metadata-probe.log")

    init() {
        // Old run data intentionally survives a crash and app restart.
        event("APP_LAUNCHED metadataDefault=OFF overridePresent=\(!urlOverride.isEmpty)")
    }

    func start(
        metadataMode: MetadataProbeMode,
        playerKind: ProbePlayerKind,
        reloadMode: ProbeReloadMode
    ) async {
        stop()
        let trimmedOverride = urlOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedOverride, forKey: "rtlHarness.urlOverride")
        let currentRun = runID
        event("RUN_PREPARE mode=\(metadataMode.rawValue) player=\(playerKind.rawValue) repeat=\(reloadMode.rawValue) override=\(!trimmedOverride.isEmpty)")
        phase = "Resolving RTL via Radio Browser"

        do {
            let stream = try await resolveURL()
            guard runID == currentRun else { return }
            guard ["http", "https"].contains(stream.scheme?.lowercased() ?? "") else {
                throw URLError(.unsupportedURL)
            }

            // An opaque URL may still redirect to an HLS playlist; this is a hint.
            let m3u8Hint = stream.absoluteString.lowercased().contains(".m3u8")
            event("STREAM_READY m3u8URLHint=\(m3u8Hint) urlRedacted=true")
            if !m3u8Hint {
                event("WARN playlist extension not visible; verify actual transport before drawing HLS conclusions")
            }

            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            event("AUDIO_SESSION active")

            load(stream: stream, metadataMode: metadataMode, playerKind: playerKind)
            if reloadMode == .twice {
                automaticReload = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1231))
                    guard !Task.isCancelled else { return }
                    guard let self, self.runID == currentRun else { return }
                    self.event("RAPID_RELOAD requestedAfterMs=1231")
                    self.load(stream: stream, metadataMode: metadataMode, playerKind: playerKind)
                }
            }
            autoStop = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                guard let self, self.runID == currentRun else { return }
                self.event("AUTO_STOP afterSeconds=180")
                self.stop()
            }
        } catch {
            guard runID == currentRun else { return }
            phase = "Failed"
            event("RUN_FAILED type=\(String(describing: type(of: error)))")
        }
    }

    func stop() {
        runID &+= 1
        automaticReload?.cancel()
        automaticReload = nil
        autoStop?.cancel()
        autoStop = nil
        tearDownItem()
        isRunning = false
        phase = "Stopped"
        event("STOP runID=\(runID)")
    }

    private func resolveURL() async throws -> URL {
        let override = urlOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            guard let url = URL(string: override) else { throw URLError(.badURL) }
            let parts = url.pathComponents
            let folder = parts.count >= 2 ? parts[parts.count - 2] : "-"
            event("STREAM_SOURCE userOverride=true host=\(url.host ?? "-") source=\(folder)/\(url.lastPathComponent)")
            return url
        }

        let endpoint = URL(
            string: "https://de1.api.radio-browser.info/json/stations/byuuid/\(Self.rtlUUID)"
        )!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("RTLMetadataHarness/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let stations = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
        guard let first = stations.first,
              let rawURL = first.url_resolved ?? first.url,
              let stream = URL(string: rawURL) else {
            throw URLError(.resourceUnavailable)
        }
        event("STREAM_SOURCE radioBrowserUUID=\(Self.rtlUUID) urlRedacted=true")
        return stream
    }

    private func load(
        stream: URL,
        metadataMode: MetadataProbeMode,
        playerKind: ProbePlayerKind
    ) {
        tearDownItem()
        itemGeneration &+= 1
        let generation = itemGeneration
        phase = "Loading · generation \(generation)"
        event("ITEM_CREATE gen=\(generation) player=\(playerKind.rawValue) mode=\(metadataMode.rawValue)")

        // Keep item construction and attach ordering equal to experimental
        // ApoloEngine: AVPlayerItem -> output -> player.insert -> play.
        let nextItem = AVPlayerItem(asset: AVURLAsset(url: stream))
        if metadataMode.installsOutput {
            let nextOutput = AVPlayerItemMetadataOutput(identifiers: metadataMode.identifiers)
            let nextSink = TimedMetadataSink { [weak self] count, titlePresent in
                NSLog("RTL_HLS_REPRO callback gen=\(generation) groups=\(count) hasTitle=\(titlePresent)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.event("METADATA_CALLBACK gen=\(generation) groups=\(count) titlePresent=\(titlePresent)")
                }
            }
            let queue: DispatchQueue = metadataMode == .titleSerial
                ? DispatchQueue(label: "com.cl0udly.rtlmetadata.serial")
                : .main
            nextOutput.setDelegate(nextSink, queue: queue)
            nextItem.add(nextOutput)
            metadataOutput = nextOutput
            metadataSink = nextSink
            event("OUTPUT_ATTACH gen=\(generation) queue=\(metadataMode == .titleSerial ? "serial" : "main")")
        }

        item = nextItem
        statusObservation = nextItem.observe(\.status, options: [.new, .initial]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation, let item = self.item else { return }
                let rawValue = item.status.rawValue
                let failure = item.error.map { String(describing: type(of: $0)) } ?? "none"
                self.event("ITEM_STATUS gen=\(generation) status=\(rawValue) errorType=\(failure)")
            }
        }

        let nextPlayer: AVPlayer
        if playerKind == .queue {
            let queuePlayer = AVQueuePlayer()
            queuePlayer.insert(nextItem, after: nil)
            nextPlayer = queuePlayer
        } else {
            nextPlayer = AVPlayer(playerItem: nextItem)
        }
        player = nextPlayer
        timeControlObservation = nextPlayer.observe(
            \.timeControlStatus, options: [.new, .initial]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation, let player = self.player else { return }
                let rawValue = player.timeControlStatus.rawValue
                self.phase = rawValue == AVPlayer.TimeControlStatus.playing.rawValue
                    ? "Playing · generation \(generation)"
                    : "Player phase \(rawValue) · generation \(generation)"
                self.event("PLAYER_TIMECONTROL gen=\(generation) state=\(rawValue)")
            }
        }
        isRunning = true
        nextPlayer.play()
        event("PLAYER_PLAY_REQUEST gen=\(generation)")
    }

    private func tearDownItem() {
        let generation = itemGeneration
        player?.pause()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil

        if let metadataOutput {
            event("OUTPUT_DETACH_BEGIN gen=\(generation)")
            metadataOutput.setDelegate(nil, queue: nil)
            if let item {
                item.remove(metadataOutput)
            }
            event("OUTPUT_DETACH_END gen=\(generation)")
        }
        metadataOutput = nil
        metadataSink = nil
        if let queuePlayer = player as? AVQueuePlayer {
            queuePlayer.removeAllItems()
        } else {
            player?.replaceCurrentItem(with: nil)
        }
        item = nil
        player = nil
        if generation > 0 {
            event("ITEM_RELEASE gen=\(generation)")
        }
    }

    private func event(_ value: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(value)"
        NSLog("RTL_HLS_REPRO %@", value)
        messages.append(line)
        if messages.count > 220 {
            messages.removeFirst(messages.count - 220)
        }
        // Persist each transition before a possible native AVFCore crash.
        // Bounded log size prevents growing indefinitely across experiments.
        let manager = FileManager.default
        let logBytes = (try? manager.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if logBytes > 512_000 {
            try? manager.removeItem(at: logURL)
        }
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                NSLog("RTL_HLS_REPRO logPersistenceFailed")
            }
        }
    }
}
