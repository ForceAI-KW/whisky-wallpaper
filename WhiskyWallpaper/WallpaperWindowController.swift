import AppKit
import AVFoundation

/// One borderless full-screen NSWindow per attached screen, sitting BELOW
/// desktop icons. AVPlayer's layer is attached as the window's contentView
/// backing layer so playback is GPU-composited (no per-frame CPU work).
///
/// "Below desktop icons" trick: set the window's level to `.below(
/// .desktopWindow)` — that's macOS's reserved level for wallpaper. The
/// system-provided wallpaper sits at exactly that level too; we replace it
/// per display by covering the same area.
///
/// `ignoresMouseEvents = true` so the user can still click through to the
/// real desktop icons + select items underneath.
final class WallpaperWindowController {
    private var windows: [NSWindow] = []
    private let player: WallpaperPlayer

    init(player: WallpaperPlayer) {
        self.player = player
        rebuildWindows()

        // React to monitor plug/unplug, resolution changes, arrangement
        // changes. Tear down + rebuild — cheaper than diffing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildWindows()
        }
    }

    /// Recreate one wallpaper window per current screen.
    func rebuildWindows() {
        // Tear down old windows + their player layers cleanly. Setting
        // contentView to nil severs the layer reference; closing the
        // window releases AppKit-side resources.
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
                .canJoinAllSpaces,           // shown on every Space
                .stationary,                 // doesn't slide on Mission Control
                .ignoresCycle,               // skipped by Cmd-` window cycle
                .fullScreenNone,             // not a fullscreen-able window
            ]
            // Below the user's desktop icons. macOS's CGShieldingWindowLevel
            // constants don't expose a "wallpaper" enum directly; the
            // standard recipe is `kCGDesktopWindowLevel - 1` so the
            // window sits beneath the wallpaper layer. Practically, both
            // values work; we use AppKit's `.below(.desktopWindow)` for
            // type safety. Note: do NOT use `.normal` or `.floating` —
            // those put the video ABOVE everything, defeating the purpose.
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false

            // Wallpaper content view: a plain NSView whose layer hosts an
            // AVPlayerLayer sized to fill. The window's frame matches the
            // screen's frame; the layer.frame matches the view's bounds.
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
            // Order BELOW everything by re-applying the level after
            // ordering. AppKit sometimes pulls borderless windows up
            // when first shown.
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

            windows.append(window)
        }

        NSLog("[WhiskyWallpaper] mounted on \(windows.count) display(s)")
    }
}

/// Custom NSView that resizes its hosted AVPlayerLayer when its bounds
/// change (e.g. screen resolution change without screen-count change).
final class WallpaperHostView: NSView {
    var hostedPlayerLayer: AVPlayerLayer?

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        hostedPlayerLayer?.frame = bounds
    }
}
