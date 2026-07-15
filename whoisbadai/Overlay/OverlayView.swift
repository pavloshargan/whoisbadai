import SwiftUI

/// The content of the transparent overlay window.
///
/// `TimelineView(.animation)` drives the frame loop: it asks for a redraw at
/// display refresh rate, but *only while this view is in a window*. When the
/// overlay is hidden, the view is removed and the whole render path costs
/// nothing. `Canvas` renders through Metal, satisfying the hardware
/// acceleration requirement without a manual CAMetalLayer.
struct OverlayView: View {
    let engine: OverlayEngine

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    // Canvas's renderer closure is nonisolated, but it is
                    // always invoked on the main thread — assumeIsolated
                    // makes that contract explicit to the compiler.
                    MainActor.assumeIsolated {
                        // tick + draw share the frame so simulation and
                        // rendering can never drift apart.
                        engine.tick(now: timeline.date, size: size)
                        engine.effect.draw(in: &context, size: size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
