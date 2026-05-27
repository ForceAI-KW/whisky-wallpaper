import Foundation
import AppKit

/// Scans the wallpaper folder for video files + drives the rotation timer.
/// One callback per rotation event tells AppDelegate "swap to this URL".
final class PlaylistManager {
    /// Called every time the timer fires with a fresh wallpaper URL.
    /// AppDelegate hands this to WallpaperPlayer.load and rebuilds the menu.
    var onRotate: ((URL) -> Void)?

    /// Called when the timer interval changes, so the menu can refresh
    /// the "Next change: in Xm" line.
    var onIntervalChange: (() -> Void)?

    private var timer: Timer?
    private(set) var nextFireDate: Date?

    init() {
        applyInterval(SettingsManager.shared.rotationIntervalMinutes)
    }

    /// Apply a new interval in minutes (0 = off).
    func applyInterval(_ minutes: Int) {
        SettingsManager.shared.rotationIntervalMinutes = minutes
        timer?.invalidate()
        timer = nil
        nextFireDate = nil

        guard minutes > 0 else {
            onIntervalChange?()
            return
        }

        let interval = TimeInterval(minutes * 60)
        nextFireDate = Date(timeIntervalSinceNow: interval)

        // RunLoop.common to survive menu-tracking + sleep transitions.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.rotateNow()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        onIntervalChange?()
    }

    /// Scan the wallpaper folder and pick a random video that's NOT the
    /// currently-playing one. If only one video exists, replay it.
    func rotateNow() {
        let folder = SettingsManager.shared.wallpaperFolderURL
        let videos = scanFolder(folder)
        guard !videos.isEmpty else {
            NSLog("[WhiskyWallpaper] rotation skipped — no videos in \(folder.path)")
            return
        }

        let current = SettingsManager.shared.currentWallpaperURL?.standardizedFileURL
        let pool = videos.count == 1
            ? videos
            : videos.filter { $0.standardizedFileURL != current }
        guard let next = pool.randomElement() else { return }

        SettingsManager.shared.setCurrentWallpaper(next)
        onRotate?(next)

        // Bump the next-fire timestamp for the menu's "next change" line.
        let interval = TimeInterval(SettingsManager.shared.rotationIntervalMinutes * 60)
        if interval > 0 {
            nextFireDate = Date(timeIntervalSinceNow: interval)
        }
        onIntervalChange?()
    }

    /// Read-only view of the current playlist (sorted alphabetically).
    var currentPlaylist: [URL] {
        scanFolder(SettingsManager.shared.wallpaperFolderURL)
    }

    /// Minutes remaining until the next rotation fires; nil if rotation
    /// is off.
    var minutesUntilNextRotation: Int? {
        guard let when = nextFireDate else { return nil }
        let s = when.timeIntervalSinceNow
        guard s > 0 else { return 0 }
        return max(1, Int((s / 60).rounded(.up)))
    }

    // MARK: - folder scan

    private func scanFolder(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        return contents
            .filter { exts.contains($0.pathExtension.lowercased()) }
            // Exclude obvious non-wallpapers: macOS screen recordings + tiny
            // clips that are likely not wallpapers (< 1 MB = noise).
            .filter { !$0.lastPathComponent.hasPrefix("Screen") }
            .filter {
                let size = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return size >= 1_000_000
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
