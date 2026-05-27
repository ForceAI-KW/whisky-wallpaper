import SwiftUI

@main
struct WhiskyWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI scenes — the whole UI lives in the menu bar + per-display
        // wallpaper windows that AppDelegate manages directly. The empty
        // `Settings` scene satisfies the @main protocol without showing a
        // window at launch.
        Settings { EmptyView() }
    }
}
