import AppKit
import SwiftUI
import Combine

/// Manages the transparent, click-through, always-on-top overlay window.
///
/// Window recipe (each line answers one requirement):
/// - `.borderless` NSPanel               → no title bar
/// - `backgroundColor = .clear` etc.     → fully transparent background
/// - `ignoresMouseEvents = true`         → clicks pass through to whatever is underneath
/// - `.nonactivatingPanel` + no key      → never steals focus
/// - `level = .screenSaver`              → above all normal app windows
/// - `collectionBehavior`                → follows the user across Spaces and over
///                                         full-screen apps
///
/// The controller observes `OverlayEngine.isVisible` and translates it into
/// window ordering + a smooth alpha fade (Core Animation, GPU-composited).
@MainActor
final class OverlayWindowController {

    private let engine: OverlayEngine
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    init(engine: OverlayEngine) {
        self.engine = engine
        cancellable = engine.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                visible ? self?.show() : self?.fadeOut()
            }
    }

    private func show() {
        let panel = ensurePanel()
        // Cover the screen the user is working on right now.
        if let screen = NSScreen.main {
            panel.setFrame(screen.frame, display: false)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()   // "Regardless": order up without activating the app
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.8
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The completion handler is @Sendable but AppKit invokes it on
            // the main thread; make that explicit for the compiler.
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // A gesture during the fade re-shows the window; only tear
                // down if we are still meant to be hidden.
                guard !self.engine.isVisible else { return }
                panel.orderOut(nil)
                self.engine.didFinishHiding()
            }
        })
    }

    /// Lazily build the panel; it survives for the app's lifetime afterwards
    /// (creating NSWindows is not free, hiding them is).
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Never become key/main: combined with .nonactivatingPanel this
        // guarantees the overlay can't steal focus from the frontmost app.
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(rootView: OverlayView(engine: engine))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        // Layer-backed hosting view → SwiftUI Canvas renders via Metal.
        hosting.wantsLayer = true
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    func shutdown() {
        panel?.orderOut(nil)
    }
}
