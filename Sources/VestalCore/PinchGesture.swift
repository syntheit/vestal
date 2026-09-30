import Foundation

// MARK: - Pinch gesture (platform-free)
//
// The trackpad pinch is four contacts that come together (open the
// dashboard) or spread apart (close it), and the dashboard's opacity follows
// the fingers, like Launchpad. The platform measures the spread of the
// contacts relative to what it was when the fourth landed (the ratio) and
// this file turns that into a direction, a progress and a verdict.

/// Which way the fingers moved. Together opens the dashboard, apart closes it.
public enum PinchDirection: Sendable, Equatable {
    case together, apart
}

public enum PinchMath {
    /// The gesture starts once the spread ratio has moved this far from 1
    /// either way, so an ordinary four-finger swipe never flashes the window.
    public static let directionThreshold: Float = 0.04
    /// Progress is 1 when the spread has shrunk to this fraction of the start.
    public static let togetherFullRatio: Float = 0.72
    /// Progress is 1 when the spread has grown to this multiple of the start.
    public static let apartFullRatio: Float = 1.35
    /// Past this progress a lift completes the gesture.
    public static let commitProgress: Float = 0.5
    /// A flick faster than this (progress per second, toward completion)
    /// completes the gesture from any progress.
    public static let flickVelocity: Float = 2.5

    /// The direction the ratio has committed to, or nil while it is still
    /// within the dead zone.
    public static func direction(ratio: Float) -> PinchDirection? {
        if ratio < 1 - directionThreshold { return .together }
        if ratio > 1 + directionThreshold { return .apart }
        return nil
    }

    /// 0...1 for a spread ratio in a direction: 0 at the start spread, 1 at
    /// the full ratio; moving back the wrong way clamps to 0.
    public static func progress(_ direction: PinchDirection, ratio: Float) -> Float {
        let value: Float
        switch direction {
        case .together: value = (1 - ratio) / (1 - togetherFullRatio)
        case .apart: value = (ratio - 1) / (apartFullRatio - 1)
        }
        return min(max(value, 0), 1)
    }

    /// What lifting the fingers does: `velocity` is the progress change per
    /// second (positive toward completion).
    public static func shouldCommit(progress: Float, velocity: Float) -> Bool {
        progress > commitProgress || velocity > flickVelocity
    }
}

/// What the platform's gesture watcher tells the resident app, on the main
/// actor. `began` comes once the direction is clear, then `changed` with the
/// progress in that direction, then `ended`.
@MainActor
public protocol GestureHandler: AnyObject {
    func gestureBegan(_ direction: PinchDirection)
    func gestureChanged(progress: Double)
    /// The fingers lifted (or changed count): `commit` says whether the
    /// gesture completes or goes back.
    func gestureEnded(commit: Bool)
}
