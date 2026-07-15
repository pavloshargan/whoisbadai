import SwiftUI

/// The app's single persisted setting.
@MainActor
final class SettingsStore: ObservableObject {

    /// Master switch. Off = no motion updates, no overlay, near-zero CPU.
    @AppStorage("enabled") var isEnabled: Bool = true {
        didSet { objectWillChange.send() }
    }
}
