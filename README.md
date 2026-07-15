# whoisbadai 🪢

A macOS app that turns your **AirPods into a motion-controlled digital whip**.
Flick your head like you're cracking a whip and a procedurally animated whip
lashes across your screen — over everything, with a crack sound — then calmly
hangs in the center until the next whip.

Inspired by the viral ["digital whip to make Claude work faster"](https://github.com/GitFrog1111/OpenWhip),
but instead of a mouse it's driven by the IMU inside your AirPods.

![whoisbadai in action](docs/whip-in-action.gif)

Built with Swift, SwiftUI, AppKit, and Core Motion — no web tech, no images
for the whip (it's all procedural), no third-party runtime dependencies.

## Requirements

- macOS 14.0+
- AirPods with head-motion support: AirPods Pro (1st/2nd gen), AirPods
  (3rd gen), AirPods Max, or Beats Fit Pro — **connected and in your ears**
  (Core Motion only streams while they're worn)

## Install

Grab the latest `whoisbadai.zip` from
[Releases](../../releases), unzip, and move `whoisbadai.app` to
`/Applications`. First launch: right-click → **Open** (the build is unsigned),
then approve **Motion & Fitness** access. Every release lists a SHA-256 so you
can verify the download.

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
rotation rate, attitude, gravity) whenever supported AirPods are connected and
worn. `HeadphoneMotionProvider` wraps it as an `AsyncStream`, so the rest of
the app just does `for await` over motion events — no timers, no polling. It
keeps listening for the life of the app and handles connect/disconnect on its
own.

### Detecting a "whip"

`ThresholdWhipDetector` is a tiny explainable state machine
(idle → arming → fire → cooldown). A whip must exceed **both** an
acceleration threshold and an angular-velocity threshold, held for a minimum
duration — requiring rotation is what separates a real head-flick from walking
or a door slam. The fired gesture carries a direction, isolated from the
peak of the swing (samples weighted by acceleration × rotation). The detector
lives behind a `GestureDetecting` protocol so it could be swapped for a
Core ML classifier without touching anything else. Cooldown caps rapid-fire
whipping at ~5 cracks/sec.

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

- Motion only streams while AirPods are **in your ears**; the status reads
  *Waiting for AirPods…* until samples arrive.
- Core Motion fires no "connected" callback if the AirPods were already paired
  at launch, so the first arriving sample is treated as the connection signal.
- Builds are **unsigned** (no Apple Developer account required to build), so
  Gatekeeper needs a right-click → Open the first time.

## License

[MIT](LICENSE) © 2026 Pavlo Sharhan
