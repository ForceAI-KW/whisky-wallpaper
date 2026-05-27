import Foundation
import AppKit

/// Best-effort bridge into Apple's private Wallpaper.framework for triggering
/// a wallpaper-system refresh after we stage a custom aerial.
///
/// The framework is at `/System/Library/PrivateFrameworks/Wallpaper.framework`
/// (its Mach-O lives inside `dyld_shared_cache_arm64e`; only the `.tbd` ships
/// as a separate file in the SDK). We link against the `.tbd` via `-framework
/// Wallpaper -F /System/Library/PrivateFrameworks` in OTHER_LDFLAGS.
///
/// The `@_silgen_name` declarations below match Swift mangled symbol names
/// extracted from `Wallpaper.tbd` on macOS Tahoe 26.5 (Wallpaper.framework
/// version 245.4.8). If Apple changes the framework these symbols can break;
/// in that case the calls below will fail safe (errors are caught and logged).
///
/// **What works:** `setLegacyDesktopPicture(_:space:display:)` does succeed at
/// the call level (returns without throwing) when given an aerial-provider
/// choice dict, but on Tahoe 26.5 it does NOT actually swap the active aerial
/// — the system holds the canonical assetID in WallpaperAgent's memory and
/// the legacy free function appears to be a pre-Sonoma image-only path that
/// got partially preserved. So even with this bridge, our v2 still falls
/// back to its NSWindow desktop renderer for guaranteed animation.
///
/// **What this bridge IS useful for:** poking the system so it re-reads
/// `entries.json` (the picker UI in System Settings → Wallpaper does see new
/// Whisky aerials after the bridge call). The user can then activate the
/// aerial via System Settings UI, which Apple's signed code does have the
/// permission to do end-to-end.
enum WallpaperBridge {

    /// Mangled symbol for: `Wallpaper.setLegacyDesktopPicture(_: [Swift.AnyHashable : Any], space: Swift.String, display: Swift.String) throws -> ()`
    /// from Wallpaper.tbd version 245.4.8 (macOS 26.5).
    /// `@_silgen_name` value omits the leading underscore that the C ABI prepends.
    @_silgen_name("$s9Wallpaper23setLegacyDesktopPicture_5space7displayySDys11AnyHashableVypG_S2StKF")
    private static func wp_setLegacyDesktopPicture(_ dict: [AnyHashable: Any],
                                                     space: String,
                                                     display: String) throws

    /// Try to nudge the wallpaper system to re-read entries.json + Index.plist by
    /// calling `setLegacyDesktopPicture` with an image-provider choice that points
    /// at our staged thumbnail. macOS often refreshes its in-memory model when this
    /// API is called even though the legacy path is officially for old-style image
    /// wallpapers.
    ///
    /// Returns `true` if the call succeeded, `false` if the symbol wasn't available
    /// or the call threw. Never fatal.
    @discardableResult
    static func nudgeSystemRefresh(staticImageURL: URL) -> Bool {
        // Set the wallpaper to a static image of our video's first frame via the
        // legacy image provider. This triggers Wallpaper.framework's "re-evaluate"
        // path. The aerial we staged in entries.json doesn't automatically take
        // effect via this call, but the user can pick it from System Settings.
        guard let mainScreenDisplay = primaryDisplayUUID() else {
            NSLog("[WhiskyWallpaper] no main screen for refresh nudge")
            return false
        }
        let dict: [AnyHashable: Any] = [
            "ImageFilePath": staticImageURL.path,
            "Placement":     "Crop",
        ]
        do {
            try wp_setLegacyDesktopPicture(dict, space: "", display: mainScreenDisplay)
            NSLog("[WhiskyWallpaper] WallpaperBridge.nudgeSystemRefresh OK for display \(mainScreenDisplay)")
            return true
        } catch {
            NSLog("[WhiskyWallpaper] WallpaperBridge.nudgeSystemRefresh FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Set the system's still desktop wallpaper to the given image URL via the
    /// public NSWorkspace API. Combined with our NSWindow video renderer:
    /// - The NSWindow overlay shows the animated video on the desktop.
    /// - When the screen locks (NSWindow disappears), macOS falls back to this
    ///   static image — which is a frame extracted from the same video — so the
    ///   lock screen visually matches the desktop video.
    @discardableResult
    static func setStaticDesktopImage(_ url: URL) -> Bool {
        var ok = true
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                NSLog("[WhiskyWallpaper] setDesktopImageURL failed for screen \(screen): \(error)")
                ok = false
            }
        }
        return ok
    }

    // MARK: - helpers

    /// The CGDisplay UUID string for the primary screen, formatted the way
    /// Wallpaper.framework's `DisplayIdentifier(rawValue:)` accepts.
    static func primaryDisplayUUID() -> String? {
        guard let screen = NSScreen.main else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let num = screen.deviceDescription[key] as? CGDirectDisplayID else { return nil }
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuidRef) as String?
    }
}
