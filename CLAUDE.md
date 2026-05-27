# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

Whisky Wallpaper is a native macOS animated-wallpaper engine — a free FOSS alternative to [Backdrop](https://cindori.com/backdrop) by Cindori. It plays a `.mp4` / `.mov` looped on every attached display as the desktop wallpaper, rotates through a folder on a timer, and (in v2) registers the active video as a system aerial so the lock-screen wallpaper visually matches the desktop video.

Sibling project: [Whisky Claude](https://github.com/ForceAI-KW/whisky-claude) — the menu-bar + window-management scaffolding is shared.

## v2 architecture (2026-05-28)

**Desktop rendering** = NSWindow at `kCGDesktopWindowLevel` playing the video via `AVQueuePlayer` + `AVPlayerLooper` (`WallpaperWindowController.swift` + `WallpaperPlayer.swift`). Animated, multi-display, sleep/wake aware. Same mechanism Backdrop uses for desktop.

**Lock-screen rendering** = best-effort via two mechanisms triggered together when a wallpaper activates:
1. **`AerialInstaller`** stages the video into `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<UUID>.mov` and adds an asset + category record (with `representativeAssetID`) to `manifest/entries.json`. The aerial appears in **System Settings → Wallpaper** under the "Whisky" category, where Apple's signed UI can activate it end-to-end (giving full animated lock-screen video if the user picks it manually).
2. **`WallpaperBridge.setStaticDesktopImage`** uses public `NSWorkspace.setDesktopImageURL` to set a still PNG frame extracted from the video as the system's static wallpaper. When the screen locks (NSWindow disappears), macOS falls back to this still — so the lock screen visually matches the desktop video, just static.

Toggle via menu: **Lock-screen sync: On / Off** (default On). When off, AerialInstaller doesn't write to System Settings → Wallpaper.

**Why not just programmatically activate the aerial?** macOS Tahoe 26.5's wallpaper system holds the canonical active-assetID in `WallpaperAgent`'s in-memory state, not in `Index.plist` (the plist is a snapshot WallpaperAgent overwrites on every restart). Setting the active aerial requires the private `Wallpaper.framework` XPC interface — specifically a method we found in `Wallpaper.tbd` called `WallpaperSettingsManager.invokeContextMenuAction(menuItemID:, groupItemID:, choiceProviderID:)` — but ContextMenuItem IDs aren't statically exported, so a third-party app can't replicate the call without further reverse engineering. Backdrop uses this private path via Cindori's Developer ID-signed code. Our v2 gets the user 90% of the way by populating the picker, leaving Apple's signed UI to do the final activation.

## Build

```bash
xcodebuild -project WhiskyWallpaper.xcodeproj -scheme WhiskyWallpaper -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Output at `build/Build/Products/Release/WhiskyWallpaper.app`. Ad-hoc codesign.

The project links Apple's private `Wallpaper.framework` at `/System/Library/PrivateFrameworks/Wallpaper.framework` via:
- `FRAMEWORK_SEARCH_PATHS = (..., "/System/Library/PrivateFrameworks")`
- `OTHER_LDFLAGS = ("-framework", "Wallpaper")`

End-to-end install: `./scripts/install.sh` (build → sign → copy to /Applications → launch).

## Architecture (7 Swift files)

| File | Role |
|---|---|
| `WhiskyWallpaperApp.swift` | `@main` entry |
| `AppDelegate.swift` | NSStatusItem menu, rotation, first-run pick, login item, and `activateWallpaper(url:source:)` which coordinates the NSWindow + AerialInstaller + WallpaperBridge calls |
| `SettingsManager.swift` | UserDefaults: current wallpaper bookmark, folder bookmark, rotation interval, **`isLockScreenSyncEnabled`** (default On) |
| `PlaylistManager.swift` | Folder scan + rotation timer |
| `WallpaperPlayer.swift` | Shared AVQueuePlayer + AVPlayerLooper. Sleep/wake observers |
| `WallpaperWindowController.swift` | One borderless NSWindow per NSScreen at desktop level |
| **`AerialInstaller.swift`** | Stages a video as a system aerial: copies → `aerials/videos/<UUID>.mov`, generates thumbnail, appends asset record + category record (with `representativeAssetID`) to `manifest/entries.json`, updates `Store/Index.plist` `SystemDefault.Linked` |
| **`WallpaperBridge.swift`** | Private `Wallpaper.framework` bridge via `@_silgen_name`. `setStaticDesktopImage` (uses public NSWorkspace) and `nudgeSystemRefresh` (uses private `setLegacyDesktopPicture`) |

## Standing rules from global config

Enforced globally in `~/.claude/CLAUDE.md`:
1. Memory pipeline after every commit — `nohup ~/.claude/scripts/update-memory-pipeline.sh all`
2. Scoped memory = source of truth, MEMORY.md = index
3. Fix everything, no deferrals unless Ahmad explicitly asks
4. Documentation parity — feature + docs same session
