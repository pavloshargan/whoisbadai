import CoreMotion
import Foundation

/// Wraps `CMHeadphoneMotionManager` and exposes headphone motion as an
/// `AsyncStream<MotionEvent>`.
///
/// Design notes:
/// - Core Motion pushes callbacks; there is no polling anywhere. The
///   `AsyncStream` is fed directly from Core Motion's handler queue and
///   consumed with `for await` by `AppState`.
/// - `CMHeadphoneMotionManager` keeps "listening forever" by itself: once
///   `startDeviceMotionUpdates` has been called it delivers connect /
///   disconnect delegate callbacks whenever compatible AirPods come and go,
///   and samples only flow while they are connected and worn. We therefore
///   never need to restart anything on reconnection.
/// - The class is not `@MainActor`: Core Motion calls back on its own
///   `OperationQueue`. Events cross to the main actor at the consumption
///   site, which keeps the motion path cheap.
final class HeadphoneMotionProvider: NSObject, CMHeadphoneMotionManagerDelegate {

    private let manager = CMHeadphoneMotionManager()

    /// Dedicated serial queue for Core Motion callbacks so the ~25–100 Hz
    /// sample stream never contends with the main thread.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.whoisbadai.motion"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var continuation: AsyncStream<MotionEvent>.Continuation?

    /// Whether this Mac + headphone combination can deliver motion at all.
    var isDeviceMotionAvailable: Bool { manager.isDeviceMotionAvailable }

    var authorizationStatus: CMAuthorizationStatus {
        CMHeadphoneMotionManager.authorizationStatus()
    }

    /// Starts listening and returns the event stream. Calling `start` again
    /// finishes the previous stream and begins a fresh one.
    func start() -> AsyncStream<MotionEvent> {
        stop()

        let (stream, continuation) = AsyncStream.makeStream(
            of: MotionEvent.self,
            // Motion samples are perishable: if the consumer ever falls
            // behind, dropping stale samples is better than queueing them.
            bufferingPolicy: .bufferingNewest(16)
        )
        self.continuation = continuation

        manager.delegate = self
        // Note: if AirPods are already connected when we start, Core Motion
        // does not fire the "did connect" delegate callback — the arrival of
        // the first sample is the only signal. AppState treats any sample as
        // proof of connection, so no special case is needed here.
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self, let continuation = self.continuation else { return }
            if let motion {
                continuation.yield(.sample(MotionSample(deviceMotion: motion)))
            } else if error != nil {
                // Errors here are almost always "not authorized" or
                // "unsupported headphones". Surface as a disconnect so the
                // UI shows a truthful status instead of silently stalling.
                continuation.yield(.disconnected)
            }
        }

        return stream
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        manager.delegate = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        continuation?.yield(.connected)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        continuation?.yield(.disconnected)
    }
}
