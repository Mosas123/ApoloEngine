import Foundation

/// Pure queue bookkeeping: current track, upcoming and history. It knows
/// nothing about playback, so the ordering rules are unit-testable.
struct PlayQueue {
    private(set) var current: ApoloTrack?
    private(set) var upcoming: [ApoloTrack] = []
    private(set) var history: [ApoloTrack] = []

    var next: ApoloTrack? { upcoming.first }

    mutating func start(_ track: ApoloTrack) {
        current = track
    }

    mutating func enqueue(_ track: ApoloTrack) {
        upcoming.append(track)
    }

    mutating func clearUpcoming() {
        upcoming.removeAll()
    }

    /// Replaces a track (matched by identity) with a version that carries the
    /// probed metadata and gain.
    @discardableResult
    mutating func replace(_ track: ApoloTrack, with updated: ApoloTrack) -> Bool {
        if let index = upcoming.firstIndex(of: track) {
            upcoming[index] = updated
            return true
        }
        if current == track {
            current = updated
            return true
        }
        return false
    }

    /// Moves to the next queued track and returns it.
    mutating func advance() -> ApoloTrack? {
        guard !upcoming.isEmpty else { return nil }
        if let current {
            history.append(current)
        }
        let next = upcoming.removeFirst()
        current = next
        return next
    }

    /// Goes back one track and returns it. The current track is pushed back
    /// onto the upcoming queue so forward works again.
    mutating func previous() -> ApoloTrack? {
        guard let previous = history.popLast() else { return nil }
        if let current {
            upcoming.insert(current, at: 0)
        }
        current = previous
        return previous
    }

    /// A host advanced into `track` on its own. Keep the queue in sync.
    @discardableResult
    mutating func consume(_ track: ApoloTrack) -> Bool {
        if let index = upcoming.firstIndex(of: track) {
            upcoming.remove(at: index)
        } else if current != track {
            return false
        }
        if let current, current != track {
            history.append(current)
        }
        current = track
        return true
    }

    mutating func clear() {
        current = nil
        upcoming.removeAll()
        history.removeAll()
    }
}
