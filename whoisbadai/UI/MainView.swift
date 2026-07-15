import SwiftUI

/// The main window: the enable checkbox plus the one-time AirPods setup that
/// keeps the left AirPod streaming motion while it's held in your hand.
struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("whoisbadai")
                .font(.largeTitle.bold())

            Toggle("Enable whoisbadai", isOn: Binding(
                get: { settings.isEnabled },
                set: { appState.setEnabled($0) }
            ))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Setup")
                    .font(.headline)

                step(1, "Open **System Settings → Bluetooth**, click the ⓘ next to your AirPods, then **AirPods Settings**.")
                step(2, "Turn **off** Automatic Ear Detection.")
                step(3, "Set **Microphone** to **Always Left AirPod**.")
                step(4, "Take the **left AirPod out and hold it in your hand** — it's your whip.")
                step(5, "Make a **whipping motion** to whip the AI. The whip appears on screen and fades out after you stop whipping.")
            }
        }
        .padding(24)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(.init(markdown))   // renders **bold** markdown inline
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
