import AppKit
import UniformTypeIdentifiers
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var player: WallpaperPlayer!
    private var windowController: WallpaperWindowController!
    private var playlist: PlaylistManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[WhiskyWallpaper] launched")

        // Menu bar icon — sparkles (matches the app icon).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles",
                                            accessibilityDescription: "Whisky Wallpaper")

        // Player + per-display windows + playlist (rotation timer).
        player = WallpaperPlayer()
        windowController = WallpaperWindowController(player: player)
        playlist = PlaylistManager()
        playlist.onRotate = { [weak self] url in
            self?.player.load(url: url)
            self?.rebuildMenu()
            NSLog("[WhiskyWallpaper] rotated to \(url.lastPathComponent)")
        }
        playlist.onIntervalChange = { [weak self] in
            self?.rebuildMenu()
        }

        statusItem.menu = buildMenu()

        // First-run UX: pick the largest video in the wallpaper folder if
        // we have no current bookmark. Browser-downloaded files (MoeWalls,
        // Pixabay, etc.) tend to be largest by far so this picks the
        // 4K headliner automatically.
        if let url = SettingsManager.shared.currentWallpaperURL,
           FileManager.default.fileExists(atPath: url.path) {
            player.load(url: url)
        } else if let firstPick = findFirstWallpaperInFolder() {
            SettingsManager.shared.setCurrentWallpaper(firstPick)
            player.load(url: firstPick)
            NSLog("[WhiskyWallpaper] first-run: picked \(firstPick.lastPathComponent)")
        } else {
            NSLog("[WhiskyWallpaper] no wallpapers found in \(SettingsManager.shared.wallpaperFolderURL.path)")
        }

        // Always-on: register as Login Item so the wallpaper survives reboot.
        registerAsLoginItem()
    }

    // MARK: - menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Now-playing header (disabled, informational).
        let currentURL = SettingsManager.shared.currentWallpaperURL
        let nowTitle: String = {
            if let url = currentURL {
                return "Now playing: \(prettyName(url))"
            }
            return "No wallpaper selected"
        }()
        let nowItem = NSMenuItem(title: nowTitle, action: nil, keyEquivalent: "")
        nowItem.isEnabled = false
        menu.addItem(nowItem)

        // Next-rotation countdown (only shown when rotation is on).
        if let mins = playlist.minutesUntilNextRotation {
            let label = mins == 0 ? "Rotating now…" : "Next change in \(mins)m"
            let nextItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            nextItem.isEnabled = false
            menu.addItem(nextItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Manual picker (file).
        let pickItem = NSMenuItem(title: "Pick wallpaper file…",
                                   action: #selector(pickWallpaperAction),
                                   keyEquivalent: "o")
        pickItem.target = self
        menu.addItem(pickItem)

        // Folder picker (scope rotation to a different dir).
        let folderItem = NSMenuItem(title: "Pick wallpaper folder…",
                                     action: #selector(pickFolderAction),
                                     keyEquivalent: "f")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(NSMenuItem.separator())

        // Rotation submenu — Off / 5m / 10m / 30m, with a checkmark on the
        // active choice.
        let rotationItem = NSMenuItem(title: "Rotation", action: nil, keyEquivalent: "")
        let rotationSub = NSMenu()
        let currentRotation = SettingsManager.shared.rotationIntervalMinutes
        for mins in SettingsManager.rotationChoices {
            let title = mins == 0 ? "Off" : "Every \(mins) minutes"
            let item = NSMenuItem(title: title,
                                   action: #selector(setRotationAction(_:)),
                                   keyEquivalent: "")
            item.target = self
            item.tag = mins
            item.state = (mins == currentRotation) ? .on : .off
            rotationSub.addItem(item)
        }
        rotationSub.addItem(NSMenuItem.separator())
        let nowSwitchItem = NSMenuItem(title: "Switch to random now",
                                        action: #selector(rotateNowAction),
                                        keyEquivalent: "n")
        nowSwitchItem.target = self
        nowSwitchItem.isEnabled = !playlist.currentPlaylist.isEmpty
        rotationSub.addItem(nowSwitchItem)
        rotationItem.submenu = rotationSub
        menu.addItem(rotationItem)

        // Playlist preview submenu (read-only list of available wallpapers).
        let playlistCount = playlist.currentPlaylist.count
        let playlistItem = NSMenuItem(title: "Playlist (\(playlistCount) videos)",
                                       action: nil, keyEquivalent: "")
        let playlistSub = NSMenu()
        if playlistCount == 0 {
            let empty = NSMenuItem(title: "No videos in folder", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            playlistSub.addItem(empty)
        } else {
            for url in playlist.currentPlaylist {
                let isActive = currentURL?.standardizedFileURL == url.standardizedFileURL
                let item = NSMenuItem(title: prettyName(url),
                                       action: #selector(pickFromPlaylistAction(_:)),
                                       keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.state = isActive ? .on : .off
                playlistSub.addItem(item)
            }
        }
        playlistItem.submenu = playlistSub
        menu.addItem(playlistItem)

        menu.addItem(NSMenuItem.separator())

        // Playback controls.
        let pauseTitle = SettingsManager.shared.isPaused ? "Resume" : "Pause"
        let pauseItem = NSMenuItem(title: pauseTitle,
                                    action: #selector(togglePauseAction),
                                    keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let reloadItem = NSMenuItem(title: "Reload wallpaper",
                                     action: #selector(reloadAction),
                                     keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder",
                                     action: #selector(revealInFinderAction),
                                     keyEquivalent: "")
        revealItem.target = self
        revealItem.isEnabled = currentURL != nil
        menu.addItem(revealItem)

        menu.addItem(NSMenuItem.separator())

        // Quit — must target NSApp (NSApplication.terminate(_:) lives on
        // the application, not the delegate). Captured in the global
        // memory file `feedback-nsmenu-quit-target-nsapp.md`.
        let quitItem = NSMenuItem(title: "Quit Whisky Wallpaper",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        return menu
    }

    private func rebuildMenu() {
        statusItem.menu = buildMenu()
    }

    // MARK: - actions

    @objc private func pickWallpaperAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie,
        ]
        panel.directoryURL = SettingsManager.shared.wallpaperFolderURL
        panel.prompt = "Set as wallpaper"
        panel.message = "Pick a video file — .mov, .mp4, or any QuickTime-playable format."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        SettingsManager.shared.setCurrentWallpaper(url)
        player.load(url: url)
        rebuildMenu()
    }

    @objc private func pickFolderAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsManager.shared.wallpaperFolderURL
        panel.prompt = "Use as wallpaper folder"
        panel.message = "Pick a folder — Whisky Wallpaper will rotate through its .mp4 / .mov files."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        SettingsManager.shared.setWallpaperFolder(url)
        rebuildMenu()
    }

    @objc private func setRotationAction(_ sender: NSMenuItem) {
        let mins = sender.tag
        playlist.applyInterval(mins)
        rebuildMenu()
    }

    @objc private func rotateNowAction() {
        playlist.rotateNow()
    }

    @objc private func pickFromPlaylistAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        SettingsManager.shared.setCurrentWallpaper(url)
        player.load(url: url)
        rebuildMenu()
    }

    @objc private func togglePauseAction() {
        player.togglePause()
        rebuildMenu()
    }

    @objc private func reloadAction() {
        windowController.rebuildWindows()
        if let url = SettingsManager.shared.currentWallpaperURL {
            player.load(url: url)
        }
    }

    @objc private func revealInFinderAction() {
        guard let url = SettingsManager.shared.currentWallpaperURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - helpers

    /// Strip the noisy "-moewalls-com" / "-pixabay" / "-shutterstock"
    /// trailer + the extension for menu display.
    private func prettyName(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        let trailers = ["-moewalls-com", "-pixabay", "-shutterstock", "-mylivewallpapers", "-mylivewallpapers-com"]
        for t in trailers {
            if let range = name.range(of: t, options: .caseInsensitive) {
                name.removeSubrange(range.lowerBound..<name.endIndex)
            }
        }
        name = name.replacingOccurrences(of: "-", with: " ")
                   .replacingOccurrences(of: "_", with: " ")
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Pick the largest video in the wallpaper folder for first-run UX.
    private func findFirstWallpaperInFolder() -> URL? {
        playlist.currentPlaylist
            .map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    private func registerAsLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                NSLog("[WhiskyWallpaper] registered as Login Item")
            } catch {
                NSLog("[WhiskyWallpaper] login item registration failed: \(error.localizedDescription)")
            }
        }
    }
}
