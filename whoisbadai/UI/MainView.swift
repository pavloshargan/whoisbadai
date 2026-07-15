import SwiftUI

/// The entire UI: one checkbox.
struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("whoisbadai")
                .font(.largeTitle.bold())

            Toggle("Enable whoisbadai", isOn: Binding(
                get: { settings.isEnabled },
                set: { appState.setEnabled($0) }
            ))
        }
        .padding(24)
        .frame(width: 260)
    }
}
