import Foundation
import AppKit
import AVFoundation

/// **PARTIAL — DO NOT WIRE INTO THE APP YET.** This file is preserved
/// as the documented schema for macOS aerial impersonation, updated
/// 2026-05-28 after deeper investigation revealed the full Backdrop
/// mechanism.
///
/// **Status update vs prior banner (corrected):**
/// - Aerial impersonation via `~/Library/Application Support/com.apple.wallpaper/`
///   IS readable by the system. Files placed there DO register.
/// - The COMPLETE recipe requires:
///   1. Video at `aerials/videos/<UUID>.mov` (use .mov, not .mp4)
///   2. Thumbnail at `aerials/thumbnails/<UUID>.png`
///   3. ASSET record in `manifest/entries.json` `assets[]`
///   4. **CATEGORY record** in `manifest/entries.json` `categories[]` with
///      `representativeAssetID` pointing back at the asset UUID — this is
///      the piece missing from the v2 attempt that failed.
///   5. `Store/Index.plist` `SystemDefault.Linked.Content.Choices` set to
///      provider `com.apple.wallpaper.choice.aerials` with assetID config.
///
/// **The actual blocker preventing FOSS adoption:** WallpaperAgent holds
/// the canonical active-assetID in-memory and OVERWRITES Index.plist with
/// its cached value on every startup. Setting Index.plist persistently
/// requires calling a private Wallpaper.framework XPC API (the same one
/// Backdrop's `BackdropKit.WallpaperManager.setWallpaperForAllSpacesAndDisplays(aerialID:)`
/// uses). Without that call, our edits are reverted by the next
/// WallpaperAgent restart.
///
/// **Reverse-engineering pathway** (for a future motivated attempt):
/// 1. Extract Wallpaper.framework from `dyld_shared_cache_arm64e` via
///    `dsc_extractor`.
/// 2. Find the XPC Mach service name (`com.apple.wallpaper`) + the
///    proxy class that exposes a "setActive(assetID:)" or similar method.
/// 3. Implement the XPC client in Swift, sign with a Developer ID, ship.
///
/// Backdrop ships a privileged daemon at `com.cindori.BackdropDaemon` but
/// our trace on 2026-05-28 confirmed Backdrop's wallpaper works WITHOUT
/// the daemon being registered — the daemon is for the "modern" idleassetsd
/// path (`/Library/Application Support/com.apple.idleassetsd/Customer/`)
/// which Backdrop uses for premium/system-wide aerials.
///
/// Test scripts (each documents one hypothesis):
/// - `scripts/test-h4-apple-category.py` — reject (wrong category UUID)
/// - `scripts/test-h6-system-default.py` — reject (missing category record)
/// - `scripts/test-h7-full-backdrop-recipe.py` — reject (matches Backdrop's
///    exact static state, still no render — runtime trigger is the gap)
///
/// Until the private Wallpaper.framework XPC is replicated, the v1 NSWindow
/// desktop wallpaper engine (`WallpaperPlayer.swift` +
/// `WallpaperWindowController.swift`) is the maximum a third-party FOSS app
/// can achieve. Backdrop ALSO uses NSWindow for desktop rendering — the
/// only thing the private API buys is lock-screen video.

final class AerialInstaller {

    private static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first!
    static let aerialBaseDir = supportDir.appendingPathComponent("com.apple.wallpaper/aerials")
    static let aerialVideosDir = aerialBaseDir.appendingPathComponent("videos")
    static let aerialThumbsDir = aerialBaseDir.appendingPathComponent("thumbnails")
    static let entriesJsonURL = aerialBaseDir.appendingPathComponent("manifest/entries.json")
    static let wallpaperIndexPlist = supportDir.appendingPathComponent("com.apple.wallpaper/Store/Index.plist")

    // Apple's existing Aerial category UUIDs (extracted from entries.json
    // on Tahoe 26.5). These are guaranteed to exist in categories[] so
    // the extension's category-membership check passes.
    private let appleAerialCategoryUUID = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    private let appleAerialSubcategoryUUID = "0DC99DD8-3386-4D1E-8878-C43E97EB710A"

    private struct ManagedAerial: Codable {
        let uuid: String
        let originalName: String
        let originalPath: String
    }
    private let kManagedList = "managedAerials"

    @discardableResult
    func installAerial(from sourceURL: URL) throws -> String {
        try ensureDirsExist()
        let uuid = UUID().uuidString
        let ext = sourceURL.pathExtension.lowercased()
        let destExt = ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov"
        let videoURL = Self.aerialVideosDir.appendingPathComponent("\(uuid).\(destExt)")
        let thumbURL = Self.aerialThumbsDir.appendingPathComponent("\(uuid).png")

        try FileManager.default.copyItem(at: sourceURL, to: videoURL)
        try generateThumbnail(from: videoURL, to: thumbURL)

        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        try insertEntriesJsonAsset(uuid: uuid,
                                    name: displayName,
                                    videoURL: videoURL,
                                    thumbURL: thumbURL)

        var managed = loadManagedAerials()
        managed.append(ManagedAerial(uuid: uuid,
                                      originalName: displayName,
                                      originalPath: sourceURL.path))
        saveManagedAerials(managed)
        NSLog("[WhiskyWallpaper] installed aerial \(uuid)")
        return uuid
    }

    func setAsActive(uuid: String) throws {
        guard let plistData = try? Data(contentsOf: Self.wallpaperIndexPlist),
              var root = try PropertyListSerialization.propertyList(from: plistData,
                                                                      options: .mutableContainersAndLeaves,
                                                                      format: nil) as? [String: Any] else {
            throw InstallerError.indexPlistMalformed
        }
        let configData = try PropertyListSerialization.data(fromPropertyList: ["assetID": uuid],
                                                              format: .binary, options: 0)
        let aerialChoice: [String: Any] = [
            "Configuration": configData,
            "Files": [],
            "Provider": "com.apple.wallpaper.choice.aerials",
        ]
        guard var displays = root["Displays"] as? [String: Any] else {
            throw InstallerError.indexPlistMalformed
        }
        for (displayId, displayRaw) in displays {
            guard var display = displayRaw as? [String: Any] else { continue }
            for slot in ["Desktop", "Idle"] {
                var slotDict = (display[slot] as? [String: Any]) ?? [:]
                var content = (slotDict["Content"] as? [String: Any]) ?? [:]
                content["Choices"] = [aerialChoice]
                content["Shuffle"] = "$null"
                slotDict["Content"] = content
                slotDict["LastSet"] = Date()
                slotDict["LastUse"] = Date()
                display[slot] = slotDict
            }
            displays[displayId] = display
        }
        root["Displays"] = displays
        let outData = try PropertyListSerialization.data(fromPropertyList: root,
                                                          format: .binary, options: 0)
        try atomicWrite(data: outData, to: Self.wallpaperIndexPlist)
        reloadWallpaperAgent()
    }

    private func generateThumbnail(from videoURL: URL, to outURL: URL) throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        var actualTime = CMTime.zero
        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: CMTime(seconds: 1.5, preferredTimescale: 600),
                                                 actualTime: &actualTime)
        } catch {
            cgImage = try generator.copyCGImage(at: .zero, actualTime: &actualTime)
        }
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw InstallerError.thumbnailGenerationFailed
        }
        try png.write(to: outURL)
    }

    private func insertEntriesJsonAsset(uuid: String,
                                          name: String,
                                          videoURL: URL,
                                          thumbURL: URL) throws {
        var json = try loadEntriesJson()
        var assets = (json["assets"] as? [[String: Any]]) ?? []
        if assets.contains(where: { ($0["id"] as? String) == uuid }) { return }

        let shotID = "CUSTOM_" + uuid.replacingOccurrences(of: "-", with: "_")
        let entry: [String: Any] = [
            "id": uuid,
            "accessibilityLabel": name,
            "localizedNameKey": name,
            "shotID": shotID,
            "showInTopLevel": true,
            "includeInShuffle": true,
            "preferredOrder": 0,
            "previewImage": "file://" + thumbURL.path,
            "url-4K-SDR-240FPS": "file://" + videoURL.path,
            "subcategories": [appleAerialSubcategoryUUID],
            "categories": [appleAerialCategoryUUID],
            "pointsOfInterest": ["0": "\(shotID)_0"],
        ]
        assets.append(entry)
        json["assets"] = assets
        try writeEntriesJson(json)
    }

    private func loadEntriesJson() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.entriesJsonURL),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.entriesJsonMalformed
        }
        return obj
    }
    private func writeEntriesJson(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json,
                                                options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data: data, to: Self.entriesJsonURL)
    }

    func managedAerials() -> [(uuid: String, name: String, path: String)] {
        loadManagedAerials().map { ($0.uuid, $0.originalName, $0.originalPath) }
    }

    func removeAerial(uuid: String) {
        for ext in ["mov", "mp4", "m4v"] {
            try? FileManager.default.removeItem(
                at: Self.aerialVideosDir.appendingPathComponent("\(uuid).\(ext)"))
        }
        try? FileManager.default.removeItem(
            at: Self.aerialThumbsDir.appendingPathComponent("\(uuid).png"))
        if var json = try? loadEntriesJson() {
            var assets = (json["assets"] as? [[String: Any]]) ?? []
            assets.removeAll { ($0["id"] as? String) == uuid }
            json["assets"] = assets
            try? writeEntriesJson(json)
        }
        var managed = loadManagedAerials()
        managed.removeAll { $0.uuid == uuid }
        saveManagedAerials(managed)
    }

    func removeAllManagedAerials() {
        for m in loadManagedAerials() {
            removeAerial(uuid: m.uuid)
        }
    }

    private func ensureDirsExist() throws {
        for dir in [Self.aerialVideosDir, Self.aerialThumbsDir,
                     Self.entriesJsonURL.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
    private func atomicWrite(data: Data, to url: URL) throws {
        let tmpURL = url.appendingPathExtension("whisky-tmp")
        try data.write(to: tmpURL, options: [.atomic])
        try FileManager.default.replaceItem(at: url,
                                              withItemAt: tmpURL,
                                              backupItemName: url.lastPathComponent + ".whisky-backup",
                                              options: [],
                                              resultingItemURL: nil)
    }
    private func reloadWallpaperAgent() {
        for name in ["WallpaperAgent", "WallpaperAerial", "WallpaperAerialsExtension"] {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [name]
            try? task.run()
            task.waitUntilExit()
        }
    }
    private func loadManagedAerials() -> [ManagedAerial] {
        guard let data = UserDefaults.standard.data(forKey: kManagedList),
              let arr = try? JSONDecoder().decode([ManagedAerial].self, from: data) else {
            return []
        }
        return arr
    }
    private func saveManagedAerials(_ list: [ManagedAerial]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: kManagedList)
        }
    }

    enum InstallerError: Error {
        case indexPlistMalformed
        case entriesJsonMalformed
        case thumbnailGenerationFailed
    }
}
