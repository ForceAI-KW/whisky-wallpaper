# Security policy

## What Whisky Wallpaper touches on your system

| Path | What | Reversible by uninstall? |
|---|---|---|
| `/Applications/Whisky Wallpaper.app` | The app bundle | yes (uninstall.sh removes it) |
| `~/Library/Preferences/com.ahmadsharaf.WhiskyWallpaper.plist` | UserDefaults: wallpaper bookmark + folder bookmark + rotation interval + pause state | yes (`defaults delete com.ahmadsharaf.WhiskyWallpaper`) |
| Login Items list | Auto-launch at boot | yes (System Settings → Login Items, or uninstall.sh) |

That's the full footprint. No `~/Library/Application Support/`, no `~/Library/Caches/`, no `~/Library/HTTPStorages/`. Whisky Wallpaper makes zero network calls so there's no cache to clear.

## What it doesn't do

- **No network access.** The binary links only `AppKit`, `AVFoundation`, `ServiceManagement`, and `UniformTypeIdentifiers`. No URLSession import, no third-party SDK.
- **No telemetry, no auto-updater, no remote config.** Updates are manual — download a new release from GitHub.
- **No PII collection.** It doesn't know who you are, doesn't log video filenames anywhere except `UserDefaults` on your local disk.
- **No microphone, no camera, no screen recording.** Plays a video file. That's it.

## How to verify

```bash
# Confirm no network frameworks are linked
otool -L /Applications/Whisky\ Wallpaper.app/Contents/MacOS/WhiskyWallpaper | grep -i "url\|http\|network"
# (expected output: nothing)

# Confirm what entitlements the app has
codesign -d --entitlements - /Applications/Whisky\ Wallpaper.app
# (expected: empty dict)
```

## Reporting a security issue

If you find a vulnerability, please email **ahmed0montaser@gmail.com** rather than opening a public issue. We'll acknowledge within 48 hours and ship a fix as fast as the scope allows.
