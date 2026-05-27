import Foundation
import AppKit
import AVFoundation

/// Registers a video file as a custom aerial in macOS's wallpaper system.
///
/// Recipe (verified by reverse-engineering Cindori Backdrop on 2026-05-28):
/// 1. Copy video to `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<UUID>.mov`
/// 2. Generate thumbnail PNG to `~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/<UUID>.png`
/// 3. Append ASSET record to `manifest/entries.json` `assets[]`
/// 4. Append CATEGORY record to `manifest/entries.json` `categories[]` with `representativeAssetID`
///    pointing back at the asset UUID. This is the piece without which the extension renders
///    Apple's representative asset instead of ours.
/// 5. Update `Store/Index.plist`'s `SystemDefault.Linked.Content.Choices` to point at the asset UUID
///    with provider `com.apple.wallpaper.choice.aerials`.
/// 6. Call `WallpaperBridge.requestRefresh` to nudge the system to pick up changes.
///
/// Once registered, the aerial appears in System Settings → Wallpaper → under the "Whisky" category.
/// The user can pick it from there and Apple's UI handles activation for both desktop + lock screen.
///
/// Whisky also separately runs an NSWindow desktop renderer (`WallpaperWindowController`) for
/// guaranteed desktop animation, since manipulating the wallpaper-extension's active aerial
/// programmatically still requires the private Wallpaper.framework API we can't fully replicate
/// without Apple-signed entitlements.
final class AerialInstaller {

    private static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first!
    static let aerialBaseDir       = supportDir.appendingPathComponent("com.apple.wallpaper/aerials")
    static let aerialVideosDir     = aerialBaseDir.appendingPathComponent("videos")
    static let aerialThumbsDir     = aerialBaseDir.appendingPathComponent("thumbnails")
    static let entriesJsonURL      = aerialBaseDir.appendingPathComponent("manifest/entries.json")
    static let wallpaperIndexPlist = supportDir.appendingPathComponent("com.apple.wallpaper/Store/Index.plist")

    /// Synthetic category UUIDs in the same shape as Backdrop's BD000000-... pattern.
    /// Using synthetic UUIDs (vs reusing Apple's) means the extension renders OUR
    /// asset as the category's representative.
    static let whiskyCategoryUUID    = "DD000000-0000-4000-8000-000000000001"
    static let whiskySubcategoryUUID = "DD000000-0000-4000-8000-000000000002"

    private struct ManagedAerial: Codable {
        let uuid: String
        let originalName: String
        let originalPath: String
    }

    private let kManagedList = "managedAerials"

    // MARK: - public API

    /// Install a video file as an aerial. Returns the asset UUID.
    /// The video is remuxed to .mov if not already (Backdrop's videos are all .mov;
    /// the aerial extension prefers .mov containers).
    @discardableResult
    func installAerial(from sourceURL: URL, displayName: String? = nil) throws -> String {
        try ensureDirsExist()
        let uuid = UUID().uuidString.uppercased()
        let videoDest = Self.aerialVideosDir.appendingPathComponent("\(uuid).mov")
        let thumbDest = Self.aerialThumbsDir.appendingPathComponent("\(uuid).png")

        try copyOrRemuxToMOV(source: sourceURL, dest: videoDest)
        try generateThumbnail(from: videoDest, to: thumbDest)

        let label = displayName ?? sourceURL.deletingPathExtension().lastPathComponent
        try insertAssetAndCategory(uuid: uuid, name: label, videoURL: videoDest, thumbURL: thumbDest)

        var managed = loadManagedAerials()
        managed.removeAll { $0.uuid == uuid }
        managed.append(ManagedAerial(uuid: uuid, originalName: label, originalPath: sourceURL.path))
        saveManagedAerials(managed)

        NSLog("[WhiskyWallpaper] installed aerial \(uuid) (name=\(label))")
        return uuid
    }

    /// Mark the given asset UUID as the active wallpaper choice across all displays + spaces.
    /// Returns true if the file write succeeded. (Whether the system extension picks it up is
    /// a separate question — see WallpaperBridge for runtime refresh.)
    func setAsActive(uuid: String) throws {
        guard let plistData = try? Data(contentsOf: Self.wallpaperIndexPlist) else {
            throw InstallerError.indexPlistMalformed
        }
        guard var root = try PropertyListSerialization.propertyList(
            from: plistData,
            options: .mutableContainersAndLeaves,
            format: nil) as? [String: Any] else {
            throw InstallerError.indexPlistMalformed
        }

        let configData = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": uuid],
            format: .binary,
            options: 0)

        let choice: [String: Any] = [
            "Configuration": configData,
            "Files": [String](),
            "Provider": "com.apple.wallpaper.choice.aerials",
        ]
        let now = Date()

        func writeContent(into parent: inout [String: Any]) {
            var content = (parent["Content"] as? [String: Any]) ?? [:]
            content["Choices"] = [choice]
            content["Shuffle"] = "$null"
            parent["Content"] = content
            parent["LastSet"] = now
            parent["LastUse"] = now
        }

        // SystemDefault.Linked
        var sysDefault = (root["SystemDefault"] as? [String: Any]) ?? [:]
        sysDefault["Type"] = "linked"
        var sdLinked = (sysDefault["Linked"] as? [String: Any]) ?? [:]
        writeContent(into: &sdLinked)
        sysDefault["Linked"] = sdLinked
        root["SystemDefault"] = sysDefault

        // Spaces.Default.Linked + force all per-space displays to inherit
        var spaces = (root["Spaces"] as? [String: Any]) ?? [:]
        var spDefault = (spaces["Default"] as? [String: Any]) ?? [:]
        spDefault["Type"] = "linked"
        var spDefaultLinked = (spDefault["Linked"] as? [String: Any]) ?? [:]
        writeContent(into: &spDefaultLinked)
        spDefault["Linked"] = spDefaultLinked
        spaces["Default"] = spDefault
        var spDisplays = (spaces["Displays"] as? [String: Any]) ?? [:]
        for (dID, d) in spDisplays {
            var dd = (d as? [String: Any]) ?? [:]
            dd["Type"] = "linked"
            dd.removeValue(forKey: "Desktop")
            dd.removeValue(forKey: "Idle")
            spDisplays[dID] = dd
        }
        spaces["Displays"] = spDisplays
        root["Spaces"] = spaces

        // AllSpacesAndDisplays (may be a sentinel string — only replace if it's a dict already)
        if var asd = root["AllSpacesAndDisplays"] as? [String: Any] {
            asd["Type"] = "linked"
            var asdLinked = (asd["Linked"] as? [String: Any]) ?? [:]
            writeContent(into: &asdLinked)
            asd["Linked"] = asdLinked
            root["AllSpacesAndDisplays"] = asd
        }

        // Top-level Displays — force linked too
        if var displays = root["Displays"] as? [String: Any] {
            for (dID, d) in displays {
                var dd = (d as? [String: Any]) ?? [:]
                dd["Type"] = "linked"
                dd.removeValue(forKey: "Desktop")
                dd.removeValue(forKey: "Idle")
                displays[dID] = dd
            }
            root["Displays"] = displays
        }

        let outData = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0)
        try atomicWrite(data: outData, to: Self.wallpaperIndexPlist)
    }

    /// List the aerials this installer has staged (so we can remove them on uninstall).
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
        // Clean up the synthetic Whisky category if empty
        if var json = try? loadEntriesJson() {
            var cats = (json["categories"] as? [[String: Any]]) ?? []
            cats.removeAll { ($0["id"] as? String) == Self.whiskyCategoryUUID }
            json["categories"] = cats
            try? writeEntriesJson(json)
        }
    }

    // MARK: - private

    private func copyOrRemuxToMOV(source: URL, dest: URL) throws {
        let srcExt = source.pathExtension.lowercased()
        if srcExt == "mov" {
            try FileManager.default.copyItem(at: source, to: dest)
            return
        }
        // Remux via AVAssetExportSession — no re-encode, just container swap to .mov.
        let asset = AVURLAsset(url: source)
        let preset = AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            // Fallback: plain copy with .mov extension
            try FileManager.default.copyItem(at: source, to: dest)
            return
        }
        session.outputURL = dest
        session.outputFileType = .mov
        let sema = DispatchSemaphore(value: 0)
        var exportError: Error?
        session.exportAsynchronously {
            if let err = session.error { exportError = err }
            sema.signal()
        }
        sema.wait()
        if let err = exportError { throw err }
    }

    private func generateThumbnail(from videoURL: URL, to outURL: URL) throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        var actualTime = CMTime.zero
        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(
                at: CMTime(seconds: 1.5, preferredTimescale: 600),
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

    /// Insert the asset record AND the Whisky category record (with representativeAssetID).
    /// Backdrop's exact pattern — the category's representativeAssetID is what makes the
    /// extension treat our asset as the renderable target.
    private func insertAssetAndCategory(uuid: String,
                                          name: String,
                                          videoURL: URL,
                                          thumbURL: URL) throws {
        var json = try loadEntriesJson()

        // ASSET
        var assets = (json["assets"] as? [[String: Any]]) ?? []
        assets.removeAll { ($0["id"] as? String) == uuid }
        let shotID = "CUSTOM_" + uuid.replacingOccurrences(of: "-", with: "_")
        let asset: [String: Any] = [
            "id":                  uuid,
            "accessibilityLabel":  name,
            "localizedNameKey":    name,
            "shotID":              shotID,
            "showInTopLevel":      true,
            "includeInShuffle":    true,
            "preferredOrder":      0,
            "previewImage":        "file://" + thumbURL.path,
            "url-4K-SDR-240FPS":   "file://" + videoURL.path,
            "subcategories":       [Self.whiskySubcategoryUUID],
            "categories":          [Self.whiskyCategoryUUID],
            "pointsOfInterest":    ["0": "\(shotID)_0"],
        ]
        assets.append(asset)
        json["assets"] = assets

        // CATEGORY — only insert if not already present (idempotent)
        var categories = (json["categories"] as? [[String: Any]]) ?? []
        let hadCategory = categories.contains { ($0["id"] as? String) == Self.whiskyCategoryUUID }
        if !hadCategory {
            let subcat: [String: Any] = [
                "id":                       Self.whiskySubcategoryUUID,
                "localizedNameKey":         "Whisky",
                "localizedDescriptionKey":  "Use Whisky Wallpaper to change custom wallpapers",
                "preferredOrder":           0,
                "previewImage":             "file://" + thumbURL.path,
                "representativeAssetID":    uuid,
            ]
            let category: [String: Any] = [
                "id":                       Self.whiskyCategoryUUID,
                "localizedNameKey":         "Whisky",
                "localizedDescriptionKey":  "Use Whisky Wallpaper to change custom wallpapers",
                "preferredOrder":           0,
                "previewImage":             "file://" + thumbURL.path,
                "representativeAssetID":    uuid,
                "subcategories":            [subcat],
            ]
            categories.append(category)
        } else {
            // Update the existing category's representativeAssetID to point at the latest aerial
            categories = categories.map { (c: [String: Any]) -> [String: Any] in
                guard let cid = c["id"] as? String, cid == Self.whiskyCategoryUUID else { return c }
                var mutc = c
                mutc["representativeAssetID"] = uuid
                mutc["previewImage"] = "file://" + thumbURL.path
                if var subs = mutc["subcategories"] as? [[String: Any]] {
                    subs = subs.map { (s: [String: Any]) -> [String: Any] in
                        guard let sid = s["id"] as? String,
                              sid == Self.whiskySubcategoryUUID else { return s }
                        var muts = s
                        muts["representativeAssetID"] = uuid
                        muts["previewImage"] = "file://" + thumbURL.path
                        return muts
                    }
                    mutc["subcategories"] = subs
                }
                return mutc
            }
        }
        json["categories"] = categories

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
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data: data, to: Self.entriesJsonURL)
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
        _ = try? FileManager.default.replaceItem(
            at: url,
            withItemAt: tmpURL,
            backupItemName: url.lastPathComponent + ".whisky-backup",
            options: [],
            resultingItemURL: nil)
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
