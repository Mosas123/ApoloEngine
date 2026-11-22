import Foundation

/// A finite AVQueuePlayer item can disappear from `currentItem` before the
/// didPlayToEnd notification fires. Its end-time evidence must instead be
/// captured against the *actual item that sent the notification*.
///
/// Values from a previous item or previous load are never eligible as an
/// end-time fallback. A missing time is unknown, NOT proof of position zero.
struct NativeEndedItemEvidence: Sendable, Equatable {
    enum PositionOrigin: String, Sendable {
        case endedItem
        case lastObserved
        case unknown
    }

    let position: TimeInterval?
    let duration: TimeInterval?
    let origin: PositionOrigin

    static func make(
        endedPosition: TimeInterval?,
        endedDuration: TimeInterval?,
        lastObservedPosition: TimeInterval?,
        lastObservedDuration: TimeInterval?,
        observationMatchesEndedItem: Bool
    ) -> NativeEndedItemEvidence {
        let endedTime = nonnegativeFinite(endedPosition)
        let observedTime = observationMatchesEndedItem
            ? nonnegativeFinite(lastObservedPosition) : nil
        // AVPlayerItem may momentarily report zero after ending. Prefer a
        // nonzero, item-matched periodic observation over that ambiguous 0.
        let useObserved = (endedTime == nil || endedTime == 0) && (observedTime ?? 0) > 0
        let position = useObserved ? observedTime : (endedTime ?? observedTime)
        let origin: PositionOrigin
        if useObserved || (endedTime == nil && observedTime != nil) {
            origin = .lastObserved
        } else if endedTime != nil {
            origin = .endedItem
        } else {
            origin = .unknown
        }

        let finishedDuration = positiveFinite(endedDuration)
        let observedDuration = observationMatchesEndedItem
            ? positiveFinite(lastObservedDuration) : nil
        return NativeEndedItemEvidence(
            position: position,
            duration: finishedDuration ?? observedDuration,
            origin: origin
        )
    }

    private static func nonnegativeFinite(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func positiveFinite(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
