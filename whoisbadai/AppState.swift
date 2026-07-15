import SwiftUI
import Combine
import CoreMotion

/// Central coordinator. Owns the pipeline
///
///     HeadphoneMotionProvider ─▶ GestureDetecting ─▶ OverlayEngine ─▶ OverlayWindowController
///
/// and exposes the enable switch plus connection status (for the menu bar).
@MainActor
final class AppState: ObservableObject {

    enum ConnectionStatus: String {
        case disabled = "Disabled"
        case waiting = "Waiting for AirPods…"
        case connected = "Connected"
        case unauthorized = "Motion access denied"
        case unavailable = "Headphone motion not supported"
    }

    @Published private(set) var connectionStatus: ConnectionStatus = .disabled

    let settings: SettingsStore
    let overlayEngine: OverlayEngine

    /// Seconds of gesture inactivity before the overlay fades out.
    private static let overlayLinger: TimeInterval = 8.0

    private let motionProvider: HeadphoneMotionProvider
    private let detector: ThresholdWhipDetector
    private let overlayController: OverlayWindowController
    private let soundPlayer = WhipSoundPlayer()
    private var pipelineTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?

    // The default is created inside the body (not as a default argument)
    // because default arguments are evaluated outside the main actor.
    init(settings: SettingsStore? = nil) {
        let settings = settings ?? SettingsStore()
        self.settings = settings

        let engine = OverlayEngine()
        self.overlayEngine = engine
        self.overlayController = OverlayWindowController(engine: engine)
        self.motionProvider = HeadphoneMotionProvider()
        self.detector = ThresholdWhipDetector(configuration: .default)

        engine.linger = Self.overlayLinger

        settingsObservation = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyEnabledState()
            }

        applyEnabledState()
    }

    // MARK: Enable / disable

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled   // observation above calls applyEnabledState()
    }

    private func applyEnabledState() {
        if settings.isEnabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private func startIfNeeded() {
        guard pipelineTask == nil else { return }

        guard motionProvider.isDeviceMotionAvailable else {
            connectionStatus = .unavailable
            return
        }
        if motionProvider.authorizationStatus == .denied {
            connectionStatus = .unauthorized
            return
        }

        connectionStatus = .waiting

        let events = motionProvider.start()
        // One long-lived task consumes the whole motion stream for the life
        // of the app. `for await` suspends between events — no polling.
        pipelineTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        motionProvider.stop()
        detector.reset()
        overlayEngine.shutdown()
        overlayController.shutdown()
        soundPlayer.shutdown()   // release the audio device while disabled
        connectionStatus = .disabled
    }

    private func handle(_ event: MotionEvent) {
        switch event {
        case .connected:
            connectionStatus = .connected
        case .disconnected:
            connectionStatus = .waiting
            detector.reset()
            overlayEngine.headphonesDisconnected()
        case .sample(let sample):
            // Delegate "did connect" doesn't fire if AirPods were already
            // connected at launch — receiving samples is the ground truth.
            if connectionStatus != .connected {
                connectionStatus = .connected
            }
            overlayEngine.handleMotion(sample)
            if let gesture = detector.process(sample) {
                overlayEngine.handleGesture(gesture)
                soundPlayer.play(intensity: gesture.intensity)
            }
        }
    }
}
