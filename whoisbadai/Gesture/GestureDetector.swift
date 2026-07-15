import Foundation
import simd

/// A recognized gesture with enough context for an effect to react
/// expressively (impulse direction, strength).
struct GestureEvent: Sendable {
    enum Kind: String, Sendable {
        case whip
    }

    let kind: Kind
    /// Device timestamp of the moment the gesture fired.
    let timestamp: TimeInterval
    /// Peak acceleration magnitude in g. Effects scale their reaction by this.
    let intensity: Double
    /// Unit vector of the dominant acceleration, in device space.
    let direction: SIMD3<Double>
}

/// Anything that can turn a stream of motion samples into gestures.
///
/// The detector is intentionally a pure push-based transformer
/// (`sample in → event out?`) with no knowledge of Core Motion, windows, or
/// effects. Swapping in a Core ML / neural network classifier later only
/// requires a new conforming type — `AppState` and everything else stay
/// untouched.
protocol GestureDetecting: AnyObject, Sendable {
    /// Feed one sample; returns a gesture if this sample completed one.
    func process(_ sample: MotionSample) -> GestureEvent?
    /// Clear internal state (e.g. after headphones disconnect).
    func reset()
}

/// Tunable parameters for the threshold detector. Kept as a plain value type
/// so the Settings UI can edit them and hand a fresh copy to the detector.
struct WhipDetectorConfiguration: Sendable, Equatable {
    /// Acceleration magnitude (g) that must be exceeded to arm the detector.
    /// A whip needs a firm, deliberate flick.
    var accelerationThreshold: Double = 3.2
    /// Angular velocity magnitude (rad/s) that must also be exceeded.
    /// A whip is a *flick*, so we require rotation, which filters out
    /// linear jolts like footsteps or a slamming door.
    var rotationThreshold: Double = 8.0
    /// The thresholds must stay exceeded for at least this long (seconds).
    /// Filters out single-sample spikes from sensor noise or a tap on the ear.
    var minimumDuration: TimeInterval = 0.04
    /// Refractory period after a detection (seconds). Caps rapid-fire
    /// whipping at ~5 cracks per second.
    var cooldown: TimeInterval = 0.2

    static let `default` = WhipDetectorConfiguration()
}

/// Simple, explainable whip detector built on thresholds + a tiny state
/// machine:
///
///     idle ──(accel & rotation above threshold)──▶ arming
///     arming ──(held for minimumDuration)────────▶ fire! → cooldown
///     arming ──(signal drops)────────────────────▶ idle
///     cooldown ──(cooldown elapsed)──────────────▶ idle
///
/// It is deliberately stateful-but-tiny; all tuning lives in
/// `WhipDetectorConfiguration`.
final class ThresholdWhipDetector: GestureDetecting, @unchecked Sendable {

    // Configuration is read/written from different threads (settings UI on
    // main, processing on the motion queue); the lock keeps that safe while
    // staying far cheaper than hopping actors on every 100 Hz sample.
    private let lock = NSLock()
    private var _configuration: WhipDetectorConfiguration

    var configuration: WhipDetectorConfiguration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    private enum State {
        case idle
        /// `weightedSum` accumulates acceleration vectors weighted by
        /// (acceleration × rotation) magnitude — samples from the
        /// high-curvature, high-g core of the stroke dominate, so the
        /// emitted direction is the *peak of the swing*, not an average of
        /// the whole gesture including its lead-in and tail. Downstream
        /// consumers (e.g. spatial calibration) rely on this isolation.
        case arming(since: TimeInterval, peak: Double, weightedSum: SIMD3<Double>)
        case cooldown(until: TimeInterval)
    }

    private var state: State = .idle

    init(configuration: WhipDetectorConfiguration = .default) {
        _configuration = configuration
    }

    func process(_ sample: MotionSample) -> GestureEvent? {
        let config = configuration
        let accel = sample.accelerationMagnitude
        let rotation = sample.rotationMagnitude
        let isHot = accel >= config.accelerationThreshold && rotation >= config.rotationThreshold

        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            if isHot {
                state = .arming(since: sample.timestamp,
                                peak: accel,
                                weightedSum: sample.userAcceleration * (accel * rotation))
            }
            return nil

        case .arming(let since, let peak, let weightedSum):
            guard isHot else {
                state = .idle
                return nil
            }
            let newPeak = max(accel, peak)
            // accel × rotation weighting isolates the stroke's core: the
            // vector already scales with |a|, so the effective weight is
            // |a|² · |ω| — the flick's peak dwarfs everything else.
            let newSum = weightedSum + sample.userAcceleration * (accel * rotation)

            if sample.timestamp - since >= config.minimumDuration {
                state = .cooldown(until: sample.timestamp + config.cooldown)
                return GestureEvent(kind: .whip,
                                    timestamp: sample.timestamp,
                                    intensity: newPeak,
                                    direction: safeNormalize(newSum))
            }
            state = .arming(since: since, peak: newPeak, weightedSum: newSum)
            return nil

        case .cooldown(let until):
            if sample.timestamp >= until {
                state = .idle
            }
            return nil
        }
    }

    func reset() {
        lock.withLock { state = .idle }
    }

    private func safeNormalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = simd_length(v)
        return length > 1e-9 ? v / length : SIMD3(1, 0, 0)
    }
}
