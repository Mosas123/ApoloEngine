import Foundation
import MediaPlayer
import UIKit

/// Publishes the Now Playing card and binds the remote commands.
@MainActor
final class NowPlayingController {
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var cachedArtwork: (hash: Int, artwork: MPMediaItemArtwork)?

    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onToggle: (@MainActor () -> Void)?
    var onSeek: (@MainActor (TimeInterval) -> Void)?

    func activate() {
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onToggle?() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.onSeek?(position) }
            return .success
        }
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true
    }

    func update(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval,
        elapsed: TimeInterval,
        isPlaying: Bool,
        isLive: Bool = false,
        artworkData: Data?
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if !isLive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        if let album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork = artwork(from: artworkData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoCenter.nowPlayingInfo = info
        commands.changePlaybackPositionCommand.isEnabled = !isLive
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
        cachedArtwork = nil
    }

    private func artwork(from data: Data?) -> MPMediaItemArtwork? {
        guard let data, let image = UIImage(data: data) else { return nil }
        let hash = data.hashValue
        if let cached = cachedArtwork, cached.hash == hash {
            return cached.artwork
        }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (hash, artwork)
        return artwork
    }
}
