import Foundation
import AppKit

/// UserDefaults-backed settings store. Single source of truth for:
/// - the currently-playing wallpaper file (security-scoped bookmark)
/// - the wallpaper folder to draw the rotation playlist from
/// - the rotation interval (0 = off, 5/10/30 minutes)
/// - the user's pause/play preference
final class SettingsManager {
    static let shared = SettingsManager()

    private let kCurrentBookmark = "currentWallpaperBookmark"
    private let kFolderBookmark  = "wallpaperFolderBookmark"
    private let kIsPaused        = "isPaused"
    private let kRotationMinutes = "rotationIntervalMinutes"

    // Rotation choices — surfaced in the menu's "Rotation" submenu.
    static let rotationChoices: [Int] = [0, 5, 10, 30]

    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: kIsPaused) }
        set { UserDefaults.standard.set(newValue, forKey: kIsPaused) }
    }

    /// Rotation interval in minutes. 0 = rotation disabled (a single
    /// wallpaper plays forever). Default = 0 on first launch so users
    /// aren't surprised by wallpapers swapping without their input.
    var rotationIntervalMinutes: Int {
        get { UserDefaults.standard.integer(forKey: kRotationMinutes) }
        set { UserDefaults.standard.set(newValue, forKey: kRotationMinutes) }
    }

    /// Resolve the bookmark for the currently-selected wallpaper file.
    /// Returns nil if no file is selected yet or the bookmark is stale.
    var currentWallpaperURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: kCurrentBookmark) else { return nil }
        return resolveBookmark(data, key: kCurrentBookmark)
    }

    @discardableResult
    func setCurrentWallpaper(_ url: URL) -> Bool {
        return persistBookmark(url, key: kCurrentBookmark)
    }

    /// Resolve the folder Whisky Wallpaper draws the playlist from.
    /// Defaults to ~/Downloads so the first-run experience plays nicely
    /// with browser downloads (MoeWalls etc.).
    var wallpaperFolderURL: URL {
        if let data = UserDefaults.standard.data(forKey: kFolderBookmark),
           let url = resolveBookmark(data, key: kFolderBookmark) {
            return url
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    @discardableResult
    func setWallpaperFolder(_ url: URL) -> Bool {
        return persistBookmark(url, key: kFolderBookmark)
    }

    // MARK: - bookmark plumbing

    private func persistBookmark(_ url: URL, key: String) -> Bool {
        let scoped: [URL.BookmarkCreationOptions] = [[.withSecurityScope], []]
        for opts in scoped {
            if let data = try? url.bookmarkData(options: opts,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: key)
                return true
            }
        }
        NSLog("[WhiskyWallpaper] failed to bookmark \(url.path)")
        return false
    }

    private func resolveBookmark(_ data: Data, key: String) -> URL? {
        for opts in [URL.BookmarkResolutionOptions([.withSecurityScope]),
                     URL.BookmarkResolutionOptions([])] {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                   options: opts,
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &isStale) {
                if isStale,
                   let fresh = try? url.bookmarkData(options: opts.contains(.withSecurityScope) ? [.withSecurityScope] : [],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: key)
                }
                return url
            }
        }
        return nil
    }
}
