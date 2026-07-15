import SwiftUI

/// The contract every visual effect implements.
///
/// The overlay engine drives effects through a fixed lifecycle:
///
///   1. `gestureDetected` when the detector fires (may fire again mid-effect)
///   2. `motionUpdated` for every motion sample while headphones stream
///   3. `update` once per rendered frame with the elapsed time and canvas size
///   4. `draw` immediately after each `update`
///
/// New effects (lightsaber, wand, laser pointer, paint brush, …) conform to
/// this protocol and register themselves in `EffectRegistry` — no other file
/// changes. Effects are `@MainActor` because they are touched only by the
/// render loop.
@MainActor
protocol GestureEffect: AnyObject {
    /// Stable identifier persisted in settings.
    static var effectID: String { get }
    /// Human-readable name for pickers.
    static var displayName: String { get }

    /// A fresh gesture. `event.intensity` and `event.direction` let the
    /// effect scale its response to how hard the user whipped.
    func gestureDetected(_ event: GestureEvent)

    /// Continuous motion while the effect is on screen, so visuals can track
    /// the head in real time (e.g. the whip handle follows yaw/pitch).
    func motionUpdated(_ sample: MotionSample)

    /// Advance the simulation. `deltaTime` is wall-clock seconds since the
    /// previous frame, already clamped by the engine.
    func update(deltaTime: TimeInterval, size: CGSize)

    /// Render the current state. Called on the SwiftUI `Canvas` context, so
    /// drawing is Metal-accelerated by the system.
    func draw(in context: inout GraphicsContext, size: CGSize)

    /// Reset all internal state (used when the overlay has fully faded out).
    func reset()
}

/// Central list of available effects. Adding an effect means adding one line
/// to `makeAll()`.
@MainActor
enum EffectRegistry {
    static func makeAll() -> [any GestureEffect] {
        [WhipEffect()]
        // Future: LightsaberEffect(), MagicWandEffect(), LaserPointerEffect(), ...
    }

    static func make(id: String) -> any GestureEffect {
        makeAll().first { type(of: $0).effectID == id } ?? WhipEffect()
    }
}
