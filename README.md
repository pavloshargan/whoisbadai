# whoisbadai 🪢

A macOS app that turns your **left AirPod into a motion-controlled digital
whip**. Hold the left AirPod in your hand, make a **whipping motion to whip
the AI**, and a procedurally animated whip lashes across your screen — over
everything, with a crack sound — then hangs in the center and fades out once
you stop whipping.

> You don't whip your head — you take the **left AirPod in your hand** and
> crack it like a whip. The IMU inside the AirPod does the rest.

Inspired by the viral ["digital whip to make Claude work faster"](https://github.com/GitFrog1111/OpenWhip),
but instead of a mouse it's driven by the IMU inside your AirPods.

![whoisbadai in action](docs/whip-demo.gif)

Built with Swift, SwiftUI, AppKit, and Core Motion — no web tech, no images
for the whip (it's all procedural), no third-party runtime dependencies.

## Requirements

- macOS 14.0+
- AirPods with motion support: AirPods Pro (1st/2nd gen), AirPods (3rd gen),
  AirPods Max, or Beats Fit Pro — connected, with the one-time **Setup** below
  so the left AirPod keeps streaming motion while held in your hand.

## Setup

Normally Core Motion only streams while an AirPod is worn. Disabling ear
detection and pinning the microphone to the left AirPod keeps it "active" — so
it keeps reporting motion in your hand, which is what you whip.

1. Open **System Settings → Bluetooth**, click the **ⓘ** next to your AirPods,
   then **AirPods Settings**.
2. Turn **off** Automatic Ear Detection.
3. Set **Microphone** to **Always Left AirPod**.
4. Take the **left AirPod out and hold it in your hand** — it's your whip.
5. Launch whoisbadai, tick **Enable whoisbadai**, and make a **whipping
   motion** to whip. The whip appears on screen and fades out after you stop.

## Install

Grab the latest `whoisbadai.zip` from [Releases](../../releases), unzip, and
move `whoisbadai.app` to `/Applications`. Every release lists a SHA-256 so you
can verify the download.

> **"whoisbadai is damaged and can't be opened"?** That's Gatekeeper, not a
> corrupt file — the build is unsigned (no Apple Developer account), so macOS
> quarantines it on download. Clear the quarantine flag once and it opens
> normally (right-click → Open does *not* work for this case):
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/whoisbadai.app
> ```

On first launch, approve **Motion & Fitness** access.

## Build from source

```sh
open whoisbadai.xcodeproj   # then ⌘R
```

or:

```sh
xcodebuild -project whoisbadai.xcodeproj -scheme whoisbadai -configuration Release build
```

## How it works

The whole app is one push-based pipeline; nothing polls.

```
CMHeadphoneMotionManager        (Core Motion pushes ~25 Hz IMU samples)
        │
HeadphoneMotionProvider         → AsyncStream<MotionEvent>
        │
ThresholdWhipDetector           → GestureEvent (a "whip", with direction)
        │
OverlayEngine + WhipEffect      → physics + rendering
        │
OverlayWindowController         → transparent, click-through, always-on-top panel
```

### Reading AirPods motion

`CMHeadphoneMotionManager` delivers device-motion samples (user acceleration,
rotation rate, attitude, gravity) from the active AirPod. With ear detection
off and the mic pinned to the left AirPod (see **Setup**), it keeps streaming
while the AirPod is held in your hand — so the whipping motion of your arm is
what the app reads. `HeadphoneMotionProvider` wraps it as an `AsyncStream`, so
the rest of the app just does `for await` over motion events — no timers, no
polling. It keeps listening for the life of the app and handles
connect/disconnect on its own.

### Detecting a "whip"

`ThresholdWhipDetector` is a tiny explainable state machine
(idle → arming → fire → cooldown). A whip must exceed **both** an
acceleration threshold and an angular-velocity threshold, held for a minimum
duration — requiring rotation is what separates a real whipping flick of the
hand from just moving the AirPod around. The fired gesture carries a
direction, isolated from the peak of the swing (samples weighted by
acceleration × rotation). The detector lives behind a `GestureDetecting`
protocol so it could be swapped for a Core ML classifier without touching
anything else. Cooldown caps rapid-fire whipping at ~5 cracks/sec.

### The whip itself

The whip is **not an asset** — every frame its shape is computed. The physics
is ported from [OpenWhip](https://github.com/GitFrog1111/OpenWhip): a tapered
Verlet chain with per-joint bend limits (stiff near the handle, floppy at the
tip), stretch capping, and screen-edge collisions, run in fixed 60 Hz substeps.

- **Idle:** the handle is pinned to the center of the screen and the rope
  hangs with a gentle organic wave.
- **Whip:** the handle swings like a real hand (wind-up → thrust → return),
  an impulse is injected down the rope, and the crack — the tip whipping past
  itself — is *emergent* from the physics, flashing a white starburst when tip
  speed spikes. A bundled sound plays, scaled by how hard you whipped.
- **Head movement** (between whips) displaces the whole rendered whip as a
  pure canvas offset — gravity-decomposed so rotation doesn't count, only real
  translation — and a spring glides it back to center. A rubber-band dead zone
  freezes sub-pixel jitter without adding any lag.

Effects conform to a `GestureEffect` protocol and register in an
`EffectRegistry`, so new ones (lightsaber, wand, laser…) are one file each.

### The overlay window

A borderless, non-activating `NSPanel` at screen-saver level that ignores
mouse events, never steals focus, joins all Spaces, and floats over
full-screen apps. It renders through a SwiftUI `Canvas` (Metal-backed) only
while visible, and tears the render loop down entirely when hidden.

### App shell

One checkbox — **Enable whoisbadai** — plus a menu bar item
(Enable/Disable/Open Settings/Quit). Closing the window keeps the app running
in the background; launch-at-login registers automatically via `SMAppService`.

## CI / Releases

GitHub-hosted macOS runners handle everything (see `.github/workflows/`):

- **CI** (`ci.yml`) — compile-checks every push and PR.
- **Release** (`release.yml`) — pushing a tag like `v1.0.0` builds a Release
  `.app`, zips it with `ditto`, computes a **SHA-256**, and publishes a GitHub
  Release with the zip + checksum file attached and the hash printed in the
  notes so downloads are verifiable.

```sh
git tag v1.0.0
git push origin v1.0.0   # → CI builds and drafts the release
```

## Notes & limitations

- Motion only streams from the **active** AirPod. Without the **Setup** above
  (ear detection off, mic pinned to the left AirPod) the AirPod goes idle the
  moment you take it out and no samples arrive — the status stays
  *Waiting for AirPods…*.
- Core Motion fires no "connected" callback if the AirPods were already paired
  at launch, so the first arriving sample is treated as the connection signal.
- Builds are **unsigned** (no Apple Developer account required to build), so
  Gatekeeper needs a right-click → Open the first time.

## License

[MIT](LICENSE) © 2026 Pavlo Sharhan
