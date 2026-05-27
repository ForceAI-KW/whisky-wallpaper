# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

Whisky Wallpaper is a native macOS animated-wallpaper engine — a free FOSS alternative to [Backdrop](https://cindori.com/backdrop) by Cindori. It plays a `.mp4` / `.mov` looped on every attached display as the desktop wallpaper, rotates through a folder on a timer, and lives in the menu bar. Pure AVFoundation + AppKit, no private APIs, no entitlements beyond default unsandboxed.

Sibling project: [Whisky Claude](https://github.com/ForceAI-KW/whisky-claude) — the menu-bar + window-management scaffolding is shared.

## Build

```bash
xcodebuild -project WhiskyWallpaper.xcodeproj -scheme WhiskyWallpaper -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Output at `build/Build/Products/Release/WhiskyWallpaper.app`. Ad-hoc codesign (no Apple Developer cert).

End-to-end install: `./scripts/install.sh` (build → sign → copy to /Applications → launch → register Login Item, idempotent).

No tests configured yet — the surface is small enough that it's been manually verified across single-display + multi-display (laptop + external) + sleep-wake cycles.

## Architecture (6 Swift files, ~625 lines)

| File | Role |
|---|---|
| `WhiskyWallpaperApp.swift` | `@main` entry, hands off to AppDelegate. Empty SwiftUI `Settings` scene so the app launches without a visible window. |
| `AppDelegate.swift` | NSStatusItem menu (rotation submenu, playlist preview, picker, pause/resume), first-run auto-pick (largest video in folder), Login Item registration via `SMAppService`. |
| `SettingsManager.swift` | UserDefaults wrapper. Security-scoped bookmark for the current wallpaper URL (survives moves) + the wallpaper folder URL. Rotation interval (0/5/10/30 min). |
| `PlaylistManager.swift` | Folder scan (`.mp4`/`.mov`/`.m4v`, ≥1MB, skips `Screen*` recordings). Rotation timer (`Timer.scheduledTimer` on `RunLoop.main` with `.common` mode). Random pick that excludes the currently-playing file. |
| `WallpaperPlayer.swift` | Shared `AVQueuePlayer` + `AVPlayerLooper` for seamless loops (no black frame at the loop point). One `AVPlayerLayer` per display; AVPlayer drives them all from a single decode pipeline. Sleep/wake observers via `NSWorkspace.willSleepNotification` / `.didWakeNotification`. |
| `WallpaperWindowController.swift` | One borderless `NSWindow` per `NSScreen` at `kCGDesktopWindowLevel` (below desktop icons). `ignoresMouseEvents = true` so icons stay clickable. Rebuilds windows on `NSApplication.didChangeScreenParametersNotification` (monitor plug/unplug). |

## Key technical choices

- **`AVPlayerLooper` not `seek(.zero)`** — looper hides the loop point seamlessly; the naive seek approach shows a black frame between iterations.
- **`NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))`** — sits below desktop icons. Re-applied after `orderFront()` because AppKit sometimes pulls borderless windows up on first show.
- **`collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`** — shown on every Space, doesn't slide on Mission Control, skipped by Cmd-` window cycle.
- **`Timer` on `RunLoop.common` mode** — rotation timer survives menu-tracking. Default `.default` mode pauses when menus are open.
- **Security-scoped bookmarks** — survive file moves + restarts. Fall back to plain bookmark if security-scoped fails (e.g. user picks a file in an unsandboxed location like `~/Downloads`).

## Entitlements + TCC permissions

Empty `WhiskyWallpaper.entitlements`. The app needs no special permissions:
- File access via `NSOpenPanel` is granted by macOS implicitly when the user picks the file
- No microphone, no camera, no AppleScript, no automation
- No network entitlement

LSUIElement = YES — menu bar only, no Dock icon.

## Standing rules from global config (cross-project)

These are enforced globally in `~/.claude/CLAUDE.md`. Summarized here so contributors who don't have the global config still see them.

1. **Memory pipeline after every commit** — `nohup ~/.claude/scripts/update-memory-pipeline.sh all` fires after each commit. Not optional.
2. **Scoped memory = source of truth, MEMORY.md = index** — detailed lessons live in `feedback-*.md` / `project-*.md` files; MEMORY.md is the pointer table.
3. **Fix everything, no "non-blocking ignored" category** — warnings + lint errors are treated as failures.
4. **Never defer a task unless Ahmad explicitly asks** — don't leave partial work or TODOs without a signal.
5. **Documentation parity** — every feature ships with docs in the same session (local commit + remote push).
