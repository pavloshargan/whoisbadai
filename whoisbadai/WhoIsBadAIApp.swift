import SwiftUI
import AppKit

/// App entry point. Scene layout:
/// - one small main window (the settings/status UI)
/// - a `MenuBarExtra` so the app stays reachable after the window closes
///
/// Closing the window must NOT quit the app — that is handled by the
/// `AppDelegate` below, while the menu bar item provides the way back in.
@main
struct WhoIsBadAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("whoisbadai", id: "main") {
            MainView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("whoisbadai", systemImage: menuBarSymbol) {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(appState.settings)
        }
    }

    private var menuBarSymbol: String {
        appState.settings.isEnabled ? "scribble.variable" : "scribble"
    }
}

/// Menu bar dropdown. Uses plain buttons/toggles so it renders as a standard
/// menu.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.connectionStatus.rawValue)

        Divider()

        if settings.isEnabled {
            Button("Disable") { appState.setEnabled(false) }
        } else {
            Button("Enable") { appState.setEnabled(true) }
        }

        Button("Open Settings") {
            openWindow(id: "main")
            // The main window scene can't activate the app by itself when
            // opened from a menu bar extra.
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit whoisbadai") {
            NSApp.terminate(nil)
        }
    }
}

/// AppKit-level behavior that SwiftUI scenes can't express.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch at login is always on — registered automatically, no UI.
        // (No-op when running from Xcode's DerivedData; SMAppService needs
        // the app to live in a stable location such as /Applications.)
        LaunchAtLogin.set(enabled: true)
    }

    /// The core "background app" behavior: last window closing keeps the
    /// process (motion pipeline, overlay, menu bar item) alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no windows open reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows
                .first { $0.identifier?.rawValue.hasPrefix("main") == true }?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }
}
