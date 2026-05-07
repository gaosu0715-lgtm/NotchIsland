# NotchIsland

NotchIsland is a small macOS experiment that turns the camera notch area on modern MacBooks into a Dynamic Island-style Apple Music overlay.

It is built with Swift, SwiftUI, and AppKit. The app uses a floating `NSPanel` and does not modify the menu bar, system files, or any private macOS frameworks.

> NotchIsland is an independent project and is not affiliated with Apple.

## Preview

The island sits near the bottom edge of the MacBook notch:

- Compact mode: album artwork on the left, waveform or paused glyph on the right.
- Expanded mode: artwork, track title, artist, album, progress, and playback controls.
- The shape morphs between compact and expanded states while staying anchored to the notch.

## Features

- Apple Music now playing display.
- Compact and expanded island states.
- Square album artwork with subtle paused-state dimming.
- Album-color waveform accent.
- Smooth morphing animation for the island shell and inner artwork.
- Play, pause, previous track, and next track controls.
- Right-click menu for common actions.
- Notch-aware positioning using public AppKit screen geometry.
- Runs as a lightweight menu-less background accessory app.

## What It Does Not Do

NotchIsland intentionally keeps the scope small:

- No system notification mirroring.
- No brightness or volume HUD replacement.
- No private `MediaRemote` APIs.
- No system menu bar modification.
- No kernel extensions, injection, or system file changes.

## Requirements

- macOS 13 Ventura or later.
- Xcode 15 or later, or Xcode Command Line Tools.
- Apple Music installed.
- A notched MacBook is recommended for the intended visual effect.

The app can run on non-notched displays too, but it will simply anchor near the top center of the screen.

## Project Structure

```text
.
├── Package.swift
├── README.md
├── Resources
│   └── Assets.xcassets
│       └── DefaultArtwork.imageset
├── Sources
│   └── NotchIsland
│       └── main.swift
└── scripts
    └── package_app.sh
```

## Build and Run

From the command line:

```bash
swift build
swift run NotchIsland
```

Or open the Swift package in Xcode:

```bash
open Package.swift
```

Then select the `NotchIsland` scheme and run it.

## Package as a macOS App

```bash
scripts/package_app.sh
open dist/NotchIsland.app
```

The packaged app is configured as an accessory app, so it does not appear in the Dock. To quit, right-click the island and choose `Quit NotchIsland`.

## Permissions

NotchIsland uses public Apple Events to read and control Apple Music. macOS may ask for permission the first time the app talks to Music.

If needed, you can check the permission manually:

1. Open System Settings.
2. Go to Privacy & Security.
3. Open Automation.
4. Allow NotchIsland to control Music.

Depending on your macOS settings, you may also need to allow Accessibility access for reliable floating overlay interaction:

1. Open System Settings.
2. Go to Privacy & Security.
3. Open Accessibility.
4. Enable NotchIsland.

## How Apple Music Data Works

The app combines a few public macOS mechanisms:

- `MPNowPlayingInfoCenter` for public now playing metadata when available.
- `DistributedNotificationCenter` for Music playback change notifications.
- Apple Events for more reliable Music metadata, artwork, progress, and playback controls.

This keeps the project inside public API boundaries while still making Apple Music integration usable.

## Notch Positioning

Apple does not expose a single fixed notch size for every MacBook model and display scaling mode. NotchIsland estimates the camera housing area with:

- `NSScreen.auxiliaryTopLeftArea`
- `NSScreen.auxiliaryTopRightArea`
- `NSScreen.safeAreaInsets`

The horizontal anchor is kept at the screen midpoint for modern MacBook Air notch layouts. The visible island dimensions are scaled from a `1710 x 1112` display-mode baseline, with extra horizontal room preserved for lower scaled resolutions such as `1280 x 832`.

## Implementation Notes

Most of the project lives in `Sources/NotchIsland/main.swift`:

- `IslandPanelController` owns the floating `NSPanel`, screen selection, and notch anchoring.
- `MorphingIslandShell` animates the island shell between compact and expanded states.
- `MusicIslandContentView` lays out artwork, waveform, text, progress, and controls.
- `WaveformView` draws the Apple Music-style animated waveform.
- `AppleMusicNowPlayingProvider` reads current Apple Music metadata.
- `AppleMusicController` sends Apple Events for playback controls and artwork reads.

The UI consumes a single `MusicSnapshot` model. To add another music provider later, implement a new provider that produces `MusicSnapshot` values and calls:

```swift
model.updateMusic(snapshot)
```

## Roadmap Ideas

- Optional providers for Spotify, NetEase Cloud Music, or QQ Music.
- User-adjustable notch offsets and island sizes.
- A lightweight preferences window.
- Optional launch-at-login helper.
- Exportable app icon and signed release builds.

## Development Notes

This is a local prototype project, not a polished App Store app. If you share builds with other Macs, unsigned apps may trigger Gatekeeper warnings. For wider distribution, sign and notarize the app with an Apple Developer account.

## License

No license has been selected yet. Add one before accepting outside contributions or redistributing the project broadly.
