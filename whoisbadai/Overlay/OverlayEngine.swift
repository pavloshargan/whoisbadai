import SwiftUI
import Combine

/// Owns the active effect and the overlay's visibility lifecycle.
///
/// Responsibilities:
/// - route gestures / motion samples to the current `GestureEffect`
/// - decide when the overlay window appears and when it fades out
///   (after `linger` seconds without a gesture)
/// - advance the effect once per rendered frame (the view calls `tick`
///   from a `TimelineView`, so frames only happen while the overlay is
///   actually on screen — zero render cost while idle)
@MainActor
final class OverlayEngine: ObservableObject {

    /// Whether the overlay window should currently exist on screen.
    @Published private(set) var isVisible = false

    private(set) var effect: any GestureEffect

    /// Seconds of gesture inactivity before fading out. Pushed from settings.
    var linger: TimeInterval = 5.0

    private var lastGestureAt: Date?
    private var lastFrameAt: Date?
    private var hideTask: Task<Void, Never>?

    /// Called by the window controller when the fade-out animation finished,
    /// so we can drop simulation state.
    var onHidden: (() -> Void)?

    // Default created in the body: default arguments are evaluated outside
    // the main actor and cannot call the @MainActor WhipEffect initializer.
    init(effect: (any GestureEffect)? = nil) {
        self.effect = effect ?? WhipEffect()
    }

    func setEffect(id: String) {
        guard type(of: effect).effectID != id else { return }
        effect = EffectRegistry.make(id: id)
    }

    // MARK: Input

    func handleGesture(_ event: GestureEvent) {
        lastGestureAt = Date()
        if !isVisible {
            lastFrameAt = nil   // avoid a giant first deltaTime
            isVisible = true
        }
        effect.gestureDetected(event)
        scheduleHide()
    }

    func handleMotion(_ sample: MotionSample) {
        // Forwarded even while hidden: effects keep their spatial state
        // (gravity axes, calibration) warm so the very first gesture after
        // an idle period still has fresh context. The per-sample work is a
        // handful of dot products — rendering stays torn down while hidden.
        effect.motionUpdated(sample)
    }

    func headphonesDisconnected() {
        // Let the current animation play out; the linger timer will hide it.
    }

    func shutdown() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
        effect.reset()
    }

    // MARK: Frame loop (called by OverlayView's TimelineView)

    func tick(now: Date, size: CGSize) {
        let dt = lastFrameAt.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastFrameAt = now
        effect.update(deltaTime: dt, size: size)
    }

    // MARK: Hiding

    private func scheduleHide() {
        hideTask?.cancel()
        // A cancellable sleeping Task is the idiomatic replacement for a
        // repeating "check if we should hide yet" timer: no polling, and a
        // new gesture simply cancels and reschedules it.
        hideTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.linger
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.isVisible = false
        }
    }

    /// Window controller reports the fade completed; reset the simulation so
    /// the next appearance starts from a clean rope.
    func didFinishHiding() {
        effect.reset()
        lastFrameAt = nil
        onHidden?()
    }
}
