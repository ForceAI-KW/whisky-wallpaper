# Whisky Wallpaper

> A free, native macOS animated-wallpaper engine. Plays 4K videos behind your desktop icons. Rotates through a folder of wallpapers on a timer. No subscription, no account, no telemetry — just AVFoundation + AppKit talking to your Mac directly.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green) ![Architecture: AppKit + AVFoundation](https://img.shields.io/badge/AppKit%20%2B%20AVFoundation-native-purple)

---

## What it does

- Plays a `.mp4` / `.mov` / `.m4v` as your **desktop wallpaper**, behind your icons
- **One wallpaper per file**, or **rotate** through a folder every 5 / 10 / 30 minutes
- **All displays** at once — one borderless `NSWindow` per `NSScreen`, auto-rebuilds on plug/unplug
- **Loops seamlessly** via `AVPlayerLooper` (no black frame at the loop point)
- **Pauses on sleep**, resumes on wake automatically
- **Login Item** — survives reboots without any extra setup
- **Click-through** — `ignoresMouseEvents = true` so your desktop icons stay clickable
- Sits in the **menu bar** as a `✨` sparkles icon — no Dock noise, no taskbar clutter

## Why it exists

[Backdrop](https://cindori.com/backdrop) by Cindori is a beautifully-built macOS animated wallpaper app — but it's subscription-priced. The actual engine is ~625 lines of straightforward Swift talking to public AVFoundation and AppKit APIs. Whisky Wallpaper is that engine, free and open.

If you're already paying for Backdrop and happy with it, keep it — they earned that money. This is for people who want the same experience without the subscription, who prefer FOSS, or who want a starting point to build something custom.

## Install

### Pre-built (recommended)

Download the latest `Whisky.Wallpaper.app.zip` from the [Releases page](https://github.com/ForceAI-KW/whisky-wallpaper/releases), unzip, and drag to `/Applications`.

First launch: right-click → Open (macOS Gatekeeper will warn — the binary is ad-hoc signed, not Developer-ID signed). After the first allow, future launches are unblocked.

### Build from source

```bash
git clone https://github.com/ForceAI-KW/whisky-wallpaper.git
cd whisky-wallpaper
./scripts/install.sh
```

The script: builds Release with ad-hoc codesign, installs to `/Applications/Whisky Wallpaper.app`, registers the app as a Login Item, launches it. Idempotent — safe to re-run.

You'll need Xcode (or the Command Line Tools) installed.

## Use

1. Drop video files into `~/Downloads/` — `.mp4` / `.mov` / `.m4v`. 4K H.264 60fps clips are ideal. Free 4K sources:
   - [MoeWalls](https://moewalls.com) — free, no signup, direct download
   - [MyLiveWallpapers](https://mylivewallpapers.com) — same
   - [Pixabay](https://pixabay.com/videos) — free, broader variety
2. Click the `✨` icon in your menu bar.
3. Pick a file via **"Pick wallpaper file…"** OR let the app auto-pick the largest video in your folder.
4. Optional: **Rotation → Every 5 / 10 / 30 minutes** to cycle through everything in the folder.

That's it.

### Menu structure

```
✨  Now playing: Astronaut Facing Black Hole
    Next change in 5m              ← only shown when rotation is on
    ──────────────────────────
    Pick wallpaper file…           ⌘O
    Pick wallpaper folder…         ⌘F
    ──────────────────────────
    Rotation                    ►   → Off
                                    → Every 5 minutes  ✓
                                    → Every 10 minutes
                                    → Every 30 minutes
                                    → ──────
                                    → Switch to random now   ⌘N
    Playlist (3 videos)         ►   → Astronaut Facing Black Hole  ✓
                                    → Galactic Horizon
                                    → UFO and Pyramid
    ──────────────────────────
    Pause                          ⌘P
    Reload wallpaper               ⌘R
    Reveal in Finder
    ──────────────────────────
    Quit Whisky Wallpaper          ⌘Q
```

The menu live-updates: now-playing title, next-rotation countdown, the active-rotation checkmark, the active-playlist checkmark.

## Privacy

- **No network calls**, ever. The binary is statically analyzable — it links only `AppKit`, `AVFoundation`, `ServiceManagement`, and `UniformTypeIdentifiers`. No analytics SDK, no telemetry, no auto-updater, no remote config.
- **No account.** It doesn't know who you are.
- **No file uploads.** Videos play from local disk via a security-scoped bookmark stored in `UserDefaults`.

## Architecture

Six Swift files, ~625 lines. All public macOS APIs — no private symbols, no entitlements beyond the default unsandboxed app.

```
WhiskyWallpaper/
├── WhiskyWallpaperApp.swift          @main entry, hands off to AppDelegate
├── AppDelegate.swift                 NSStatusItem menu, first-run, Login Item
├── SettingsManager.swift             UserDefaults + security-scoped bookmarks
├── PlaylistManager.swift             folder scan + rotation timer
├── WallpaperPlayer.swift             AVQueuePlayer + AVPlayerLooper, sleep/wake observers
└── WallpaperWindowController.swift   one NSWindow per NSScreen at kCGDesktopWindowLevel
```

### Key technical choices

- **`AVPlayerLooper`** for the loop — seamless transitions vs. the naive `seek(.zero)` approach which shows a black frame between iterations.
- **One `AVQueuePlayer` for all displays** — frames stay synced across monitors; AVPlayer drives multiple layers from a single decode pipeline.
- **`NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))`** — sits behind desktop icons. Re-applied after `orderFront()` because AppKit sometimes pulls borderless windows up on first show.
- **`collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`** — shown on every Space, doesn't slide on Mission Control, skipped by Cmd-` window cycle.
- **`ignoresMouseEvents = true`** — desktop icon clicks pass through.
- **`NSApplication.didChangeScreenParametersNotification`** — tears down + rebuilds wallpaper windows on monitor plug/unplug.
- **`NSWorkspace.willSleepNotification` / `.didWakeNotification`** — pauses AVPlayer on sleep, resumes on wake unless user explicitly paused.

### Setting your own default folder

In `AppDelegate.applicationDidFinishLaunching`, first-run picks the **largest** video in `~/Downloads/` — 4K wallpapers from MoeWalls / Pixabay / etc. are typically 50-150MB which biases the pick toward "the thing the user just downloaded for this app." If you keep wallpapers somewhere else, switch via **Pick wallpaper folder…**.

## What it doesn't do

- **Lock-screen video.** macOS doesn't expose a public API for that — you'd need a separate `.saver` screensaver bundle. Roadmap item; PRs welcome.
- **In-app browsing of online wallpaper libraries.** Whisky Wallpaper plays files you already have. Use MoeWalls / Pixabay / your own DSLR clips to source them.
- **Per-display different wallpapers.** All displays mirror the same video. Could be added — not currently a goal.
- **Touch-bar shenanigans, widgets, control-center plugins.** Just a wallpaper engine.

## Requirements

- **macOS 13** (Ventura) or later
- A reasonably modern Mac (any Apple Silicon, or Intel Mac with hardware H.264 decode)
- **No** Apple Developer account needed — Whisky Wallpaper ships ad-hoc signed
- **No** Backdrop / other wallpaper app needed running — uninstall those first to avoid double-wallpaper situations

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the app, the Login Item, and all `UserDefaults` traces under `com.ahmadsharaf.WhiskyWallpaper`. Your video files stay where they are.

## Credits

- Inspired by [**Backdrop**](https://cindori.com/backdrop) by Cindori — the polished commercial app whose engine this rebuilds in the open.
- Menu-bar + window-management scaffolding is shared with [**Whisky Claude**](https://github.com/ForceAI-KW/whisky-claude), the sibling project for Claude Code companion features.

## License

MIT — see [LICENSE](./LICENSE).

You're welcome to redistribute, fork, modify, and ship commercial products built on top of this. Just keep the copyright notice. The wallpapers you play are not subject to this license — they have their own (usually the original creator's CC-BY or similar terms). Respect what the source site says.

## Issues / contributions

Issues + PRs welcome at [github.com/ForceAI-KW/whisky-wallpaper](https://github.com/ForceAI-KW/whisky-wallpaper). For wider questions about the Force AI ecosystem (Whisky Claude, the rest of the Force toolset), see [forcemediakw.com](https://forcemediakw.com).
