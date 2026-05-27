import AppKit
import UniformTypeIdentifiers
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var player: WallpaperPlayer!
    private var windowController: WallpaperWindowController!
    private var playlist: PlaylistManager!
    private let aerialInstaller = AerialInstaller()
    private var currentAerialUUID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[WhiskyWallpaper] launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles",
                                            accessibilityDescription: "Whisky Wallpaper")

        player = WallpaperPlayer()
        windowController = WallpaperWindowController(player: player)
        playlist = PlaylistManager()
        playlist.onRotate = { [weak self] url in
            self?.activateWallpaper(url: url, source: "rotation")
            self?.rebuildMenu()
        }
        playlist.onIntervalChange = { [weak self] in
            self?.rebuildMenu()
        }

        statusItem.menu = buildMenu()

        if let url = SettingsManager.shared.currentWallpaperURL,
           FileManager.default.fileExists(atPath: url.path) {
            activateWallpaper(url: url, source: "launch")
        } else if let firstPick = findFirstWallpaperInFolder() {
            SettingsManager.shared.setCurrentWallpaper(firstPick)
            activateWallpaper(url: firstPick, source: "first-run")
        } else {
            NSLog("[WhiskyWallpaper] no wallpapers found in \(SettingsManager.shared.wallpaperFolderURL.path)")
        }

        registerAsLoginItem()
    }

    /// Single activation path. Updates:
    /// - NSWindow video (animated desktop)
    /// - Lock-screen static image (frame extracted from video, set via NSWorkspace)
    /// - Aerial registration (`entries.json` + `Index.plist`) — populates the
    ///   System Settings → Wallpaper picker so the user can manually select
    ///   the aerial there for full lock-screen video support if they want
    private func activateWallpaper(url: URL, source: String) {
        NSLog("[WhiskyWallpaper] activate(\(source)) -> \(url.lastPathComponent)")
        SettingsManager.shared.setCurrentWallpaper(url)
        player.load(url: url)

        // Lock-screen + aerial registration is best-effort. Failure here doesn't
        // block the NSWindow desktop rendering above.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.tryAerialAndLockScreenSync(videoURL: url)
        }
    }

    private func tryAerialAndLockScreenSync(videoURL: URL) {
        guard SettingsManager.shared.isLockScreenSyncEnabled else {
            NSLog("[WhiskyWallpaper] lock-screen sync disabled — skipping aerial registration")
            return
        }
        do {
            let displayName = self.prettyName(videoURL)
            let uuid = try aerialInstaller.installAerial(from: videoURL, displayName: displayName)
            try aerialInstaller.setAsActive(uuid: uuid)

            // Extract still frame for lock-screen / fallback image. The aerial
            // installer already wrote a .png thumbnail at the staged path.
            let thumbURL = AerialInstaller.aerialThumbsDir.appendingPathComponent("\(uuid).png")
            if FileManager.default.fileExists(atPath: thumbURL.path) {
                _ = WallpaperBridge.setStaticDesktopImage(thumbURL)
                _ = WallpaperBridge.nudgeSystemRefresh(staticImageURL: thumbURL)
            }

            DispatchQueue.main.async { [weak self] in
                self?.currentAerialUUID = uuid
                self?.rebuildMenu()
            }
            NSLog("[WhiskyWallpaper] aerial sync OK: uuid=\(uuid)")
        } catch {
            NSLog("[WhiskyWallpaper] aerial sync FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let currentURL = SettingsManager.shared.currentWallpaperURL
        let nowTitle: String = {
            if let url = currentURL { return "Now playing: \(prettyName(url))" }
            return "No wallpaper selected"
        }()
        let nowItem = NSMenuItem(title: nowTitle, action: nil, keyEquivalent: "")
        nowItem.isEnabled = false
        menu.addItem(nowItem)

        if let mins = playlist.minutesUntilNextRotation {
            let label = mins == 0 ? "Rotating now…" : "Next change in \(mins)m"
            let nextItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            nextItem.isEnabled = false
            menu.addItem(nextItem)
        }

        menu.addItem(NSMenuItem.separator())

        let pickItem = NSMenuItem(title: "Pick wallpaper file…",
                                   action: #selector(pickWallpaperAction),
                                   keyEquivalent: "o")
        pickItem.target = self
        menu.addItem(pickItem)

        let folderItem = NSMenuItem(title: "Pick wallpaper folder…",
                                     action: #selector(pickFolderAction),
                                     keyEquivalent: "f")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(NSMenuItem.separator())

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

        let lockSyncTitle = SettingsManager.shared.isLockScreenSyncEnabled
            ? "Lock-screen sync: On"
            : "Lock-screen sync: Off"
        let lockSyncItem = NSMenuItem(title: lockSyncTitle,
                                       action: #selector(toggleLockScreenSyncAction),
                                       keyEquivalent: "l")
        lockSyncItem.target = self
        lockSyncItem.toolTip = "When on, Whisky registers the current video as an aerial in System Settings → Wallpaper and sets a still frame of it as the lock-screen image."
        menu.addItem(lockSyncItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder",
                                     action: #selector(revealInFinderAction),
                                     keyEquivalent: "")
        revealItem.target = self
        revealItem.isEnabled = currentURL != nil
        menu.addItem(revealItem)

        menu.addItem(NSMenuItem.separator())

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
        activateWallpaper(url: url, source: "menu-pick")
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
        playlist.applyInterval(sender.tag)
        rebuildMenu()
    }

    @objc private func rotateNowAction() {
        playlist.rotateNow()
    }

    @objc private func pickFromPlaylistAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        activateWallpaper(url: url, source: "menu-playlist")
        rebuildMenu()
    }

    @objc private func toggleLockScreenSyncAction() {
        SettingsManager.shared.isLockScreenSyncEnabled.toggle()
        if SettingsManager.shared.isLockScreenSyncEnabled,
           let url = SettingsManager.shared.currentWallpaperURL {
            // Just enabled — sync the current wallpaper
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.tryAerialAndLockScreenSync(videoURL: url)
            }
        } else if !SettingsManager.shared.isLockScreenSyncEnabled {
            // Just disabled — remove our aerials so we don't pollute the user's picker
            aerialInstaller.removeAllManagedAerials()
            currentAerialUUID = nil
        }
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
