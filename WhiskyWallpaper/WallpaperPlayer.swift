import AVFoundation
import AVKit
import AppKit

/// Owns a single AVPlayer + one AVPlayerLayer per screen. The same player
/// drives every screen — frames synced, audio muted. On sleep/wake AVPlayer
/// often stalls; observers on `NSWorkspace.willSleepNotification` and
/// `.didWakeNotification` pause/resume cleanly.
final class WallpaperPlayer {
    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private(set) var playerLayers: [AVPlayerLayer] = []

    init() {
        self.player = AVQueuePlayer()
        self.player.isMuted = true
        self.player.actionAtItemEnd = .advance
        self.player.automaticallyWaitsToMinimizeStalling = false
        self.player.allowsExternalPlayback = false

        installSleepWakeHandlers()
    }

    deinit {
        if let s = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(s) }
        if let w = wakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(w) }
        if let s = spaceChangeObserver { NSWorkspace.shared.notificationCenter.removeObserver(s) }
    }

    /// Load a new file. Tears down the previous loop, builds a fresh one.
    func load(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // AVPlayerLooper is the canonical way to loop a single asset
        // forever on AVQueuePlayer. It keeps a phantom second queue entry
        // so playback transitions are seamless (no black frame at the loop
        // point, which a manual seek(.zero) approach would show).
        self.looper = AVPlayerLooper(player: player, templateItem: item)
        if SettingsManager.shared.isPaused {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Create a layer ready to attach to a wallpaper window's contentView.
    /// One layer per screen; AVPlayer drives them all from the same source.
    func makeLayer() -> AVPlayerLayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        playerLayers.append(layer)
        return layer
    }

    func play() {
        SettingsManager.shared.isPaused = false
        player.play()
    }

    func pause() {
        SettingsManager.shared.isPaused = true
        player.pause()
    }

    func togglePause() {
        if player.rate == 0 { play() } else { pause() }
    }

    var isPlaying: Bool { player.rate != 0 }

    // MARK: - sleep/wake handling

    private func installSleepWakeHandlers() {
        let nc = NSWorkspace.shared.notificationCenter

        sleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.player.pause()
        }

        wakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if !SettingsManager.shared.isPaused {
                self.player.play()
            }
        }

        spaceChangeObserver = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !SettingsManager.shared.isPaused else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.player.play()
            }
        }
    }
}
