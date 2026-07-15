import SwiftUI
import simd

/// Whip effect — physics and rendering ported from OpenWhip
/// (https://github.com/GitFrog1111/OpenWhip, overlay.html).
///
/// Deliberately simple: the handle is pinned to the center of the screen and
/// never moves. The rope idles under gravity with its handle aimed up-right;
/// a detected whip injects a velocity impulse (side chosen from the
/// gesture's direction) and the OpenWhip physics — tapered Verlet chain,
/// bend limits, stretch cap, screen-edge collisions — produces the lash.
/// Cracks are emergent: the starburst fires when the tip speed spikes.
///
/// OpenWhip's constants are per-frame at 60 fps, so the simulation runs on a
/// fixed 60 Hz substep accumulator regardless of display refresh rate.
@MainActor
final class WhipEffect: GestureEffect {

    static let effectID = "whip"
    static let displayName = "Whip"

    // MARK: Tuning (adapted from OpenWhip's P)

    private enum P {
        // Rope structure
        static let segments = 20
        static let segmentLength = 20.0     // base length of each link (px)
        static let taper = 0.6              // tip link is this fraction of base

        // Physics
        static let gravity = 1.0            // px per step²
        static let damping = 0.93           // velocity retention per step
        static let constraintIters = 20
        static let maxStretchRatio = 1.2

        // Fixed handle aim ("up-right") guiding the first links
        static let handleAngle = -1.12      // radians
        static let basePoseSegments = 2
        static let basePoseStiffStart = 0.9
        static let basePoseStiffEnd = 0.8

        // Elastic bend limits by chain position (handle stiff, tip can fold
        // over — a crack needs the tip to whip past itself)
        static let handleMaxBendDeg = 14.0
        static let tipMaxBendDeg = 110.0
        static let bendRigidityStart = 0.8
        static let bendRigidityEnd = 0.15

        // Screen-edge slap
        static let wallBounce = 0.42
        static let wallFriction = 0.86

        // Crack detection
        static let crackSpeed = 200.0       // tip px per step
        static let crackCooldown = 0.2      // s
        static let firstCrackGrace = 0.35   // s after spawn

        // Whip impulse
        static let impulseGain = 75.0       // px/step of tip velocity per g
        static let intensityCap = 4.0       // g
        static let settleDuration = 0.7     // s of stronger damping post-whip
        static let settleDamping = 0.90
        static let lashDuration = 0.25      // s of full energy before settling

        // Handle swing: the hand movement of the whip. The pinned handle
        // winds up backward, thrusts forward along the lash direction, and
        // eases back to center; the handle's aim rotates through the swing.
        static let swingDuration = 0.5      // s
        static let swingAmplitude = 110.0   // px of handle travel
        static let aimSwing = 1.0           // radians of aim rotation at peak

        // Visuals
        static let lineWidthHandle = 7.0
        static let lineWidthTip = 5.0
        static let outlineWidth = 3.0
        static let handleExtraWidth = 5.0
        static let handleThickSegments = 2

        // Initial arc shape
        static let arcWidth = 180.0
        static let arcHeight = 125.0

        static let stepTime = 1.0 / 60.0
    }

    // MARK: AirPods translation → display offset
    //
    // Head translation displaces the WHOLE rendered whip (a pure canvas
    // offset in draw()) and never touches the simulation — the animation is
    // identical whether you're holding still or sliding it around.
    private enum T {
        static let velocityGain = 5200.0     // px/s of offset motion per g
        static let biasTime = 2.5            // s, drift estimator
        static let velocitySmoothing = 0.015 // s
        static let recenterTime = 1.1        // s, spring back to center
        static let jitterFloorG = 0.035      // below: no response at all
        static let fullResponseKneeG = 0.10  // above: exactly linear
        static let saturationG = 0.45        // spikes can't fling it
        static let maxOffsetFraction = 0.40  // of screen width/height
        /// After a whip the whip is HELD at center for this long — the
        /// whip's own after-shock acceleration is discarded instead of
        /// sliding the whip away mid-crack.
        static let postWhipHold = 0.6       // s

        /// Positional dead zone (rubber band): the rendered offset trails
        /// the raw one by up to this many px. Jitter oscillating inside the
        /// band freezes completely; real movement passes through the same
        /// frame (it just trails by this constant distance) — zero time lag.
        static let positionDeadZone = 10.0   // px
        /// Slow creep toward the raw offset inside the dead zone, so the
        /// whip settles exactly instead of parking a band-width off.
        static let deadZoneCreepTime = 1.5   // s
    }

    // MARK: State

    private struct RopePoint {
        var x: Double, y: Double
        var px: Double, py: Double   // previous position (Verlet)
    }

    private var whip: [RopePoint] = []
    private var accumulator: TimeInterval = 0
    private var spawnedAt: TimeInterval = 0
    private var lastCrackAt: TimeInterval = -1
    private var pendingImpulse: SIMD2<Double>?
    private var settleUntil: TimeInterval = -1

    // Active handle swing (the "hand" part of the whip).
    private var swingStart: TimeInterval = -1
    private var swingDirection = SIMD2<Double>(1, -1) / sqrt(2)
    private var swingSide = 1.0
    private var currentAim = P.handleAngle

    // Translation (display offset) state.
    private var displayOffset = SIMD2<Double>.zero
    private var offsetVelocity = SIMD2<Double>.zero
    private var accelBias = SIMD2<Double>.zero
    private var lastSampleTime: TimeInterval?
    private var clampedOffset = SIMD2<Double>.zero   // what draw() applies
    private var stableOffset = SIMD2<Double>.zero    // dead-zone-filtered offset
    private var holdCenterUntil: TimeInterval = -1

    /// Accumulated animation clock (sum of frame deltas — no wall clock).
    private var time: TimeInterval = 0
    private var crackFlash = 0.0

    // MARK: GestureEffect

    func gestureDetected(_ event: GestureEvent) {
        // Lash toward the side of the head flick. The AirPods x-axis points
        // to the user's LEFT, so screen-right is the negated device x.
        let side: Double = -event.direction.x >= 0 ? 1 : -1
        let direction = SIMD2(side, -1) / sqrt(2)   // upward diagonal
        let strength = min(event.intensity, P.intensityCap) * P.impulseGain
        pendingImpulse = direction * strength

        // Kick off the handle swing.
        swingStart = time
        swingDirection = direction
        swingSide = side

        // Every whip recenters, and the whip holds center while the crack
        // plays out (the hold is enforced per-frame in update()).
        displayOffset = .zero
        offsetVelocity = .zero
        holdCenterUntil = time + T.postWhipHold
    }

    func motionUpdated(_ sample: MotionSample) {
        let dt: TimeInterval
        if let last = lastSampleTime {
            dt = min(max(sample.timestamp - last, 0), 0.1)
        } else {
            dt = 0
        }
        lastSampleTime = sample.timestamp
        guard dt > 0 else { return }

        // Gravity-stable decomposition: vertical from the measured gravity
        // vector, horizontal from the ear axis flattened into the horizontal
        // plane — rotating the head does not move the whip.
        let gravity = sample.gravity
        let gravityLength = simd_length(gravity)
        guard gravityLength > 0.5 else { return }
        let down = gravity / gravityLength

        var earAxis = SIMD3<Double>(1, 0, 0) - down * down.x
        let earLength = simd_length(earAxis)
        guard earLength > 0.1 else { return }
        earAxis /= earLength

        // Direction from the (ear, down) projection, magnitude from the full
        // 3D vector (movement is assumed parallel to the screen plane), and
        // the ear projection negated (device x points to the user's LEFT).
        let ax = -simd_dot(sample.userAcceleration, earAxis)
        let ay = simd_dot(sample.userAcceleration, down)
        var raw = SIMD2(ax, ay)
        let planar = simd_length(raw)
        let full = simd_length(sample.userAcceleration)
        if planar > 1e-6 { raw *= full / planar }

        // Remove slow drift, gate jitter with a tight soft knee, saturate.
        accelBias += (raw - accelBias) * min(dt / T.biasTime, 1.0)
        var accel = raw - accelBias
        let magnitude = simd_length(accel)
        if magnitude > 1e-9 {
            let ramp = smoothstep((magnitude - T.jitterFloorG)
                                  / (T.fullResponseKneeG - T.jitterFloorG))
            let effective = min(magnitude * ramp, T.saturationG)
            accel *= effective / magnitude
        } else {
            accel = .zero
        }

        let targetVelocity = accel * T.velocityGain
        offsetVelocity += (targetVelocity - offsetVelocity)
            * min(dt / T.velocitySmoothing, 1.0)
        displayOffset += offsetVelocity * dt
    }

    func update(deltaTime: TimeInterval, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let dt = min(deltaTime, 1.0 / 30.0)
        time += dt

        // Display offset: spring home, clamp to the screen. During the
        // post-whip hold, stay planted at center and dump any velocity the
        // whip's after-shock fed in.
        if time < holdCenterUntil {
            displayOffset = .zero
            offsetVelocity = .zero
            stableOffset = .zero   // hold means EXACT center, band included
        }
        displayOffset *= exp(-dt / T.recenterTime)
        let maxX = Double(size.width) * T.maxOffsetFraction
        let maxY = Double(size.height) * T.maxOffsetFraction
        let raw = SIMD2(min(max(displayOffset.x, -maxX), maxX),
                        min(max(displayOffset.y, -maxY), maxY))

        // Rubber-band dead zone: continuous jitter around one spot renders
        // rock-still; real motion drags the band along at full speed.
        let delta = raw - stableOffset
        let distance = simd_length(delta)
        if distance > T.positionDeadZone {
            stableOffset = raw - delta / distance * T.positionDeadZone
        } else {
            stableOffset += (raw - stableOffset) * min(dt / T.deadZoneCreepTime, 1.0)
        }
        clampedOffset = stableOffset

        // The handle rests at screen center; during a whip it swings —
        // windup back, thrust forward, ease home — and its aim rotates.
        let center = SIMD2(Double(size.width) * 0.5, Double(size.height) * 0.5)
        var anchor = center
        currentAim = P.handleAngle
        if swingStart >= 0 {
            let u = (time - swingStart) / P.swingDuration
            if u < 1 {
                let p = swingProfile(u)
                anchor = center + swingDirection * (P.swingAmplitude * p)
                currentAim = P.handleAngle + swingSide * P.aimSwing * p
            } else {
                swingStart = -1
            }
        }
        if whip.isEmpty { spawn(at: anchor) }

        // A whip kicks the rope: velocity grows toward the free end.
        if let impulse = pendingImpulse {
            pendingImpulse = nil
            for i in 2..<whip.count {
                let t = Double(i) / Double(whip.count - 1)
                whip[i].px -= impulse.x * t
                whip[i].py -= impulse.y * t
            }
            settleUntil = time + P.settleDuration
        }

        // Fixed-timestep substeps keep OpenWhip's per-frame constants exact.
        accumulator += dt
        var steps = 0
        while accumulator >= P.stepTime, steps < 4 {
            physicsStep(anchor: anchor, size: size)
            accumulator -= P.stepTime
            steps += 1
        }
        if steps == 4 { accumulator = 0 }   // hitch: drop time, stay stable

        crackFlash = max(0, crackFlash - dt * 3.0)
    }

    // MARK: OpenWhip physics

    private func spawn(at anchor: SIMD2<Double>) {
        whip = (0..<P.segments).map { i in
            let t = Double(i) / Double(P.segments - 1)
            let x = anchor.x + t * P.arcWidth
            let y = anchor.y - sin(t * .pi * 0.75) * P.arcHeight
            return RopePoint(x: x, y: y, px: x, py: y)
        }
        spawnedAt = time
        lastCrackAt = -1
    }

    private func segLen(_ i: Int) -> Double {
        let t = Double(i) / Double(P.segments - 1)
        return P.segmentLength * (1 - t * (1 - P.taper))
    }

    private func physicsStep(anchor: SIMD2<Double>, size: CGSize) {
        // Verlet integration. The lash keeps full energy briefly, then the
        // settle window strengthens damping so the aftermath calms fast.
        let inLash = time < settleUntil - P.settleDuration + P.lashDuration
        let damping = (time < settleUntil && !inLash) ? P.settleDamping : P.damping
        for i in 1..<whip.count {
            var p = whip[i]
            let vx = (p.x - p.px) * damping
            let vy = (p.y - p.py) * damping
            p.px = p.x
            p.py = p.y
            p.x += vx
            p.y += vy + P.gravity
            whip[i] = p
        }

        // Pin handle to the (possibly swinging) anchor.
        whip[0] = RopePoint(x: anchor.x, y: anchor.y, px: anchor.x, py: anchor.y)

        capSegmentStretch()
        applyWallCollisions(size: size)
        applyBasePose()

        for _ in 0..<P.constraintIters {
            for i in 0..<(whip.count - 1) {
                let a = whip[i], b = whip[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let dist = max(sqrt(dx * dx + dy * dy), 1e-4)
                let target = segLen(i)
                let diff = (dist - target) / dist * 0.5
                let ox = dx * diff, oy = dy * diff
                if i == 0 {
                    // Handle is pinned — push only the next point.
                    whip[i + 1].x -= ox * 2
                    whip[i + 1].y -= oy * 2
                } else {
                    whip[i].x += ox
                    whip[i].y += oy
                    whip[i + 1].x -= ox
                    whip[i + 1].y -= oy
                }
            }
            applyBendLimits()
            applyBasePose()
            capSegmentStretch()
            applyWallCollisions(size: size)
        }

        // Emergent crack: tip speed above threshold → starburst flash.
        let tip = whip[whip.count - 1]
        let tipVel = hypot(tip.x - tip.px, tip.y - tip.py)
        if tipVel > P.crackSpeed,
           time - spawnedAt >= P.firstCrackGrace,
           time - lastCrackAt > P.crackCooldown {
            lastCrackAt = time
            crackFlash = 1.0
        }
    }

    /// Windup → thrust → ease-home profile for the handle swing.
    /// Negative = pulled back, +1 = full forward extension.
    private func swingProfile(_ u: Double) -> Double {
        if u < 0.2 {
            return -0.6 * smoothstep(u / 0.2)                 // wind up backward
        } else if u < 0.5 {
            return lerp(-0.6, 1.0, smoothstep((u - 0.2) / 0.3)) // snap forward
        } else {
            return lerp(1.0, 0.0, smoothstep((u - 0.5) / 0.5))  // ease home
        }
    }

    /// Guide the first links along the current (swinging) handle aim.
    private func applyBasePose() {
        let dx = cos(currentAim)
        let dy = sin(currentAim)
        let guided = min(P.basePoseSegments, whip.count - 1)
        guard guided >= 1 else { return }
        for i in 1...guided {
            let t = Double(i - 1) / Double(max(guided - 1, 1))
            let stiff = lerp(P.basePoseStiffStart, P.basePoseStiffEnd, t)
            let prev = whip[i - 1]
            let targetLen = segLen(i - 1)
            whip[i].x = lerp(whip[i].x, prev.x + dx * targetLen, stiff)
            whip[i].y = lerp(whip[i].y, prev.y + dy * targetLen, stiff)
        }
    }

    /// Clamp the bend angle at each joint — stiff near the handle, looser
    /// toward the tip.
    private func applyBendLimits() {
        guard whip.count >= 3 else { return }
        for i in 1..<(whip.count - 1) {
            let a = whip[i - 1], b = whip[i], c = whip[i + 1]

            let v1x = a.x - b.x, v1y = a.y - b.y
            let v2x = c.x - b.x, v2y = c.y - b.y
            let l1 = max(hypot(v1x, v1y), 1e-4)
            let l2 = max(hypot(v2x, v2y), 1e-4)
            let n1x = v1x / l1, n1y = v1y / l1
            let n2x = v2x / l2, n2y = v2y / l2

            let dot = min(max(n1x * n2x + n1y * n2y, -1), 1)
            let angle = acos(dot)
            let t = Double(i) / Double(whip.count - 2)
            let maxBend = lerp(P.handleMaxBendDeg, P.tipMaxBendDeg, t) * .pi / 180
            let bend = .pi - angle
            if bend <= maxBend { continue }

            let cross = n1x * n2y - n1y * n2x
            let sign = cross >= 0 ? 1.0 : -1.0
            let targetA = atan2(n1y, n1x) + sign * (Double.pi - maxBend)
            let tx = b.x + cos(targetA) * l2
            let ty = b.y + sin(targetA) * l2
            let rigidity = lerp(P.bendRigidityStart, P.bendRigidityEnd, t)

            whip[i + 1].x = lerp(c.x, tx, rigidity)
            whip[i + 1].y = lerp(c.y, ty, rigidity)
        }
    }

    /// Hard cap on per-link stretch during violent motion.
    private func capSegmentStretch() {
        guard whip.count >= 2 else { return }
        for i in 0..<(whip.count - 1) {
            let a = whip[i], b = whip[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let dist = max(hypot(dx, dy), 1e-4)
            let maxLen = segLen(i) * P.maxStretchRatio
            if dist <= maxLen { continue }
            let k = maxLen / dist
            whip[i + 1].x = a.x + dx * k
            whip[i + 1].y = a.y + dy * k
        }
    }

    /// Screen edges are walls: the whip slaps and bounces off them.
    private func applyWallCollisions(size: CGSize) {
        let w = Double(size.width), h = Double(size.height)
        for i in 1..<whip.count {
            var p = whip[i]
            var vx = p.x - p.px
            var vy = p.y - p.py
            var hit = false

            if p.x < 0 {
                p.x = 0
                if vx < 0 { vx = -vx * P.wallBounce }
                vy *= P.wallFriction
                hit = true
            } else if p.x > w {
                p.x = w
                if vx > 0 { vx = -vx * P.wallBounce }
                vy *= P.wallFriction
                hit = true
            }

            if p.y < 0 {
                p.y = 0
                if vy < 0 { vy = -vy * P.wallBounce }
                vx *= P.wallFriction
                hit = true
            } else if p.y > h {
                p.y = h
                if vy > 0 { vy = -vy * P.wallBounce }
                vx *= P.wallFriction
                hit = true
            }

            if hit {
                p.px = p.x - vx
                p.py = p.y - vy
                whip[i] = p
            }
        }
    }

    // MARK: Rendering (OpenWhip style: white halo + dark tapered core)

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard whip.count >= 2 else { return }

        // Head translation displaces the whole rendered whip; the simulation
        // underneath is untouched.
        context.translateBy(x: CGFloat(clampedOffset.x), y: CGFloat(clampedOffset.y))

        let white = Color.white
        let dark = Color(white: 0.066)   // #111

        // White halo: full spline at tip width + outline.
        var halo = Path()
        halo.move(to: CGPoint(x: whip[0].x, y: whip[0].y))
        for i in 0..<(whip.count - 1) {
            addBezier(&halo, from: i)
        }
        context.stroke(halo, with: .color(white),
                       style: StrokeStyle(lineWidth: P.lineWidthTip + P.outlineWidth * 2,
                                          lineCap: .round, lineJoin: .round))

        // Extra white thickness over the handle links.
        let thickLinks = min(P.handleThickSegments, whip.count - 1)
        if thickLinks > 0 {
            var handleHalo = Path()
            handleHalo.move(to: CGPoint(x: whip[0].x, y: whip[0].y))
            for i in 0..<thickLinks {
                addBezier(&handleHalo, from: i)
            }
            let width = P.lineWidthHandle + P.handleExtraWidth + P.outlineWidth * 2
            context.stroke(handleHalo, with: .color(white),
                           style: StrokeStyle(lineWidth: width,
                                              lineCap: .round, lineJoin: .round))
        }

        // Dark core, per-segment so the width tapers handle → tip.
        for i in 0..<(whip.count - 1) {
            let t = Double(i) / Double(max(1, whip.count - 2))
            let extra = i < P.handleThickSegments ? P.handleExtraWidth : 0
            let width = lerp(P.lineWidthHandle, P.lineWidthTip, t) + extra
            var seg = Path()
            seg.move(to: CGPoint(x: whip[i].x, y: whip[i].y))
            addBezier(&seg, from: i)
            context.stroke(seg, with: .color(dark),
                           style: StrokeStyle(lineWidth: width,
                                              lineCap: .round, lineJoin: .round))
        }

        // Crack starburst at the tip.
        if crackFlash > 0.01, let tip = whip.last {
            let tipPoint = CGPoint(x: tip.x, y: tip.y)
            let alpha = crackFlash
            let glowRadius: CGFloat = 34
            context.fill(
                Path(ellipseIn: CGRect(x: tipPoint.x - glowRadius, y: tipPoint.y - glowRadius,
                                       width: glowRadius * 2, height: glowRadius * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(alpha * 0.95),
                                      Color.white.opacity(0)]),
                    center: tipPoint, startRadius: 0, endRadius: glowRadius))

            let rayLength = 18 + (1 - alpha) * 42
            for i in 0..<6 {
                let angle = Double(i) / 6 * 2 * .pi
                var ray = Path()
                ray.move(to: tipPoint)
                ray.addLine(to: CGPoint(x: tipPoint.x + CGFloat(cos(angle)) * rayLength,
                                        y: tipPoint.y + CGFloat(sin(angle)) * rayLength))
                context.stroke(ray, with: .color(Color.white.opacity(alpha * 0.9)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }

    func reset() {
        whip.removeAll()
        crackFlash = 0
        time = 0
        accumulator = 0
        pendingImpulse = nil
        settleUntil = -1
        swingStart = -1
        displayOffset = .zero
        offsetVelocity = .zero
        accelBias = .zero
        lastSampleTime = nil
        clampedOffset = .zero
        stableOffset = .zero
    }

    // MARK: Spline helpers (Catmull–Rom → cubic Bézier, as in the original)

    private func catmullPoint(_ i: Int) -> CGPoint {
        let n = whip.count
        if i < 0 {
            if n >= 2 {
                return CGPoint(x: 2 * whip[0].x - whip[1].x,
                               y: 2 * whip[0].y - whip[1].y)
            }
            return CGPoint(x: whip[0].x, y: whip[0].y)
        }
        if i >= n {
            if n >= 2 {
                let a = whip[n - 2], b = whip[n - 1]
                return CGPoint(x: 2 * b.x - a.x, y: 2 * b.y - a.y)
            }
            return CGPoint(x: whip[n - 1].x, y: whip[n - 1].y)
        }
        return CGPoint(x: whip[i].x, y: whip[i].y)
    }

    /// Append the Bézier for link i→i+1 (assumes the current point is at i).
    private func addBezier(_ path: inout Path, from i: Int) {
        let p0 = catmullPoint(i - 1)
        let p1 = catmullPoint(i)
        let p2 = catmullPoint(i + 1)
        let p3 = catmullPoint(i + 2)
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
