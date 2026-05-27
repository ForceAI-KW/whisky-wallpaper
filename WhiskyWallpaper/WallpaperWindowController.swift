import AppKit
import AVFoundation

/// One borderless full-screen NSWindow per attached screen, sitting BELOW
/// desktop icons. AVPlayer's layer is attached as the window's contentView
/// backing layer so playback is GPU-composited (no per-frame CPU work).
///
/// `ignoresMouseEvents = true` so the user can still click through to the
/// real desktop icons + select items underneath.
final class WallpaperWindowController {
    private var windows: [NSWindow] = []
    private let player: WallpaperPlayer

    init(player: WallpaperPlayer) {
        self.player = player
        rebuildWindows()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildWindows()
        }
    }

    func rebuildWindows() {
        for w in windows {
            w.contentView = nil
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()

        for screen in NSScreen.screens {
            let frame = screen.frame
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenNone,
            ]
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false

            let content = WallpaperHostView()
            content.wantsLayer = true
            content.layer = CALayer()
            content.layer?.backgroundColor = NSColor.black.cgColor

            let playerLayer = player.makeLayer()
            playerLayer.frame = content.bounds
            playerLayer.needsDisplayOnBoundsChange = true
            content.layer?.addSublayer(playerLayer)
            content.hostedPlayerLayer = playerLayer

            window.contentView = content
            window.orderFront(nil)
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

            windows.append(window)
        }

        NSLog("[WhiskyWallpaper] mounted on \(windows.count) display(s)")
    }
}

final class WallpaperHostView: NSView {
    var hostedPlayerLayer: AVPlayerLayer?
    override var isFlipped: Bool { false }
    override func layout() {
        super.layout()
        hostedPlayerLayer?.frame = bounds
    }
}
