# whoisbadai 🪢

This is first app in the world that uses an Airpod as a handheld IMU controller

Turn your **left AirPod into a digital whip**. Hold it in your hand, crack it
like a whip, and an animated whip lashes across your screen with a sound — then
fades out when you stop.

Inspired by [OpenWhip](https://github.com/GitFrog1111/OpenWhip), but driven by
the motion sensor inside an AirPod instead of a mouse.

![whoisbadai in action](docs/whip-demo.gif)

Built with Swift, SwiftUI, and Core Motion. The whip is drawn procedurally — no
images, no third-party dependencies.

## Requirements

macOS 14+ and AirPods with motion support (AirPods Pro, AirPods 3rd gen, AirPods
Max, or Beats Fit Pro).

## Setup

An AirPod only reports motion while it's "active," so a one-time tweak keeps the
left one streaming while it's in your hand:

1. **System Settings → Bluetooth → ⓘ next to your AirPods → AirPods Settings**
2. Turn **off** Automatic Ear Detection
3. Set **Microphone** to **Always Left AirPod**
4. Hold the **left AirPod in your hand** — that's your whip
5. Launch the app, tick **Enable**, and whip

## Install

Download `whoisbadai.zip` from [Releases](../../releases), unzip, and drag
`whoisbadai.app` to `/Applications`. On first launch, approve **Motion &
Fitness**.

The build is unsigned, so macOS may claim it's "damaged." Clear the quarantine
flag once (right-click → Open won't work for this):

```sh
xattr -dr com.apple.quarantine /Applications/whoisbadai.app
```

## Build from source

```sh
open whoisbadai.xcodeproj   # then ⌘R
```

## How it works

Core Motion streams the AirPod's accelerometer and gyro. A small detector fires
a "whip" on a sharp flick, and a procedural rope-physics whip (ported from
OpenWhip) cracks across a transparent, click-through overlay on top of
everything. Closing the window keeps it running in the menu bar.

## License

[MIT](LICENSE) © 2026 Pavlo Sharhan
