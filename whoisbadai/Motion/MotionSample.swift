import CoreMotion
import simd

/// A single, immutable snapshot of headphone motion.
///
/// This is the app's own value type rather than `CMDeviceMotion` so that
/// everything downstream of `HeadphoneMotionProvider` (gesture detection,
/// overlay physics, tests) is decoupled from Core Motion. A future neural
/// network classifier can consume the exact same samples.
struct MotionSample: Sendable {
    /// Device timestamp in seconds (monotonic, from `CMDeviceMotion.timestamp`).
    let timestamp: TimeInterval

    /// User-generated acceleration in g, gravity already removed by Core Motion.
    let userAcceleration: SIMD3<Double>

    /// Gravity direction in the *device frame*, in g (points toward the
    /// ground, magnitude ≈ 1). Lets consumers decompose acceleration into
    /// true vertical/horizontal components regardless of head orientation.
    let gravity: SIMD3<Double>

    /// Angular velocity in radians/second.
    let rotationRate: SIMD3<Double>

    /// Attitude (orientation) of the headphones in radians.
    let roll: Double
    let pitch: Double
    let yaw: Double

    /// Magnitude of user acceleration in g. The primary "whip" signal.
    var accelerationMagnitude: Double { simd_length(userAcceleration) }

    /// Magnitude of angular velocity in rad/s. Distinguishes a sharp head
    /// flick from linear motion such as walking or a bus braking.
    var rotationMagnitude: Double { simd_length(rotationRate) }

    init(deviceMotion motion: CMDeviceMotion) {
        timestamp = motion.timestamp
        userAcceleration = SIMD3(motion.userAcceleration.x,
                                 motion.userAcceleration.y,
                                 motion.userAcceleration.z)
        gravity = SIMD3(motion.gravity.x,
                        motion.gravity.y,
                        motion.gravity.z)
        rotationRate = SIMD3(motion.rotationRate.x,
                             motion.rotationRate.y,
                             motion.rotationRate.z)
        roll = motion.attitude.roll
        pitch = motion.attitude.pitch
        yaw = motion.attitude.yaw
    }

    /// Memberwise initializer, useful for unit tests and synthetic input.
    init(timestamp: TimeInterval,
         userAcceleration: SIMD3<Double>,
         gravity: SIMD3<Double> = SIMD3(0, -1, 0),
         rotationRate: SIMD3<Double>,
         roll: Double, pitch: Double, yaw: Double) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
    }
}

/// Events emitted by the motion provider. Connection changes and samples
/// travel through one stream so consumers see them in order.
enum MotionEvent: Sendable {
    case connected
    case disconnected
    case sample(MotionSample)
}
