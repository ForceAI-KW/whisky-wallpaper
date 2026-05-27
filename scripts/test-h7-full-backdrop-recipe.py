#!/usr/bin/env python3
"""
Hypothesis 7 test: replicate Backdrop's COMPLETE recipe (decoded from a
working Backdrop install on Tahoe 26.5, 2026-05-28).

The missing piece in all prior attempts: we added an asset record but
never added a corresponding CATEGORY record with `representativeAssetID`
pointing BACK at our asset UUID. The extension renders a category's
representative — if our asset isn't the representative of any category
that EXISTS in `categories[]`, it's invisible.

Also: video file extension matters. Backdrop uses .mov. We tried .mp4.
Re-test with .mov.

Usage:
    python3 scripts/test-h7-full-backdrop-recipe.py <video.mp4 or .mov>

KEEP_TEST_STATE=1 — leave the wallpaper active so you can see it visually.
"""
import sys
import os
import uuid
import json
import shutil
import subprocess
import time
import plistlib
from pathlib import Path
from datetime import datetime

SUPPORT = Path.home() / "Library/Application Support/com.apple.wallpaper"
AERIALS = SUPPORT / "aerials"
VIDEOS = AERIALS / "videos"
THUMBS = AERIALS / "thumbnails"
ENTRIES_JSON = AERIALS / "manifest" / "entries.json"
INDEX_PLIST = SUPPORT / "Store" / "Index.plist"

# Our synthetic category UUIDs (matching Backdrop's BD000000 pattern but
# with WW prefix so they don't collide if Backdrop is also installed).
WHISKY_CATEGORY_UUID = "DD000000-0000-4000-8000-000000000001"
WHISKY_SUBCATEGORY_UUID = "DD000000-0000-4000-8000-000000000002"


def log(msg):
    print(f"[h7-test] {msg}", flush=True)


def install_aerial(asset_uuid, video_dest, thumb_dest, display_name):
    """Add asset record + category record with representativeAssetID."""
    entries = json.loads(ENTRIES_JSON.read_text())
    backup = ENTRIES_JSON.with_suffix(".json.h7backup")
    backup.write_text(ENTRIES_JSON.read_text())

    shot_id = "CUSTOM_" + asset_uuid.replace("-", "_")

    # ASSET RECORD
    asset = {
        "id": asset_uuid,
        "accessibilityLabel": display_name,
        "localizedNameKey": display_name,
        "shotID": shot_id,
        "showInTopLevel": True,
        "includeInShuffle": True,
        "preferredOrder": 0,
        "previewImage": f"file://{thumb_dest}",
        "url-4K-SDR-240FPS": f"file://{video_dest}",
        "subcategories": [WHISKY_SUBCATEGORY_UUID],
        "categories": [WHISKY_CATEGORY_UUID],
        "pointsOfInterest": {"0": f"{shot_id}_0"},
    }
    # Replace any existing asset with the same id
    entries["assets"] = [a for a in entries.get("assets", []) if a.get("id") != asset_uuid]
    entries["assets"].append(asset)

    # CATEGORY RECORD with representativeAssetID — THE MISSING PIECE
    category = {
        "id": WHISKY_CATEGORY_UUID,
        "localizedNameKey": "Whisky",
        "localizedDescriptionKey": "Custom wallpapers via Whisky Wallpaper",
        "preferredOrder": 0,
        "previewImage": f"file://{thumb_dest}",
        "representativeAssetID": asset_uuid,
        "subcategories": [
            {
                "id": WHISKY_SUBCATEGORY_UUID,
                "localizedNameKey": "Whisky",
                "localizedDescriptionKey": "Custom wallpapers via Whisky Wallpaper",
                "preferredOrder": 0,
                "previewImage": f"file://{thumb_dest}",
                "representativeAssetID": asset_uuid,
            }
        ],
    }
    # Replace any existing Whisky category
    entries["categories"] = [c for c in entries.get("categories", [])
                              if c.get("id") != WHISKY_CATEGORY_UUID]
    entries["categories"].append(category)

    ENTRIES_JSON.write_text(json.dumps(entries, indent=2, sort_keys=True))
    log(f"  asset + category records written to entries.json")
    return backup


def set_active_wallpaper(asset_uuid):
    with open(INDEX_PLIST, "rb") as f:
        root = plistlib.load(f, fmt=plistlib.FMT_BINARY)
    backup = INDEX_PLIST.with_suffix(".plist.h7backup")
    with open(backup, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)

    cfg_data = plistlib.dumps({"assetID": asset_uuid}, fmt=plistlib.FMT_BINARY)
    choice = {
        "Configuration": cfg_data,
        "Files": [],
        "Provider": "com.apple.wallpaper.choice.aerials",
    }

    now = datetime.now()

    def write(parent):
        content = parent.get("Content") or {}
        content["Choices"] = [choice]
        content["Shuffle"] = "$null"
        parent["Content"] = content
        parent["LastSet"] = now
        parent["LastUse"] = now

    # SystemDefault.Linked — primary
    sd = root.get("SystemDefault") or {}
    sd["Type"] = "linked"
    sd_linked = sd.get("Linked") or {}
    write(sd_linked)
    sd["Linked"] = sd_linked
    root["SystemDefault"] = sd

    # Spaces.Default.Linked
    spaces = root.get("Spaces") or {}
    sp_def = spaces.get("Default") or {}
    sp_def["Type"] = "linked"
    sp_def_linked = sp_def.get("Linked") or {}
    write(sp_def_linked)
    sp_def["Linked"] = sp_def_linked
    spaces["Default"] = sp_def
    # Force per-space displays to inherit
    for d_id, d in (spaces.get("Displays") or {}).items():
        d["Type"] = "linked"
        d.pop("Desktop", None)
        d.pop("Idle", None)
    root["Spaces"] = spaces

    # AllSpacesAndDisplays
    asd = root.get("AllSpacesAndDisplays")
    if isinstance(asd, dict):
        asd["Type"] = "linked"
        asd_linked = asd.get("Linked") or {}
        write(asd_linked)
        asd["Linked"] = asd_linked
        root["AllSpacesAndDisplays"] = asd

    # Legacy Displays — force linked
    for d_id, d in (root.get("Displays") or {}).items():
        d["Type"] = "linked"
        d.pop("Desktop", None)
        d.pop("Idle", None)

    with open(INDEX_PLIST, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
    log(f"  Index.plist active wallpaper set to {asset_uuid[:8]}..")
    return backup


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    src = Path(sys.argv[1])
    if not src.exists():
        log(f"FATAL: source video missing: {src}")
        sys.exit(2)

    asset_uuid = str(uuid.uuid4()).upper()

    # Backdrop uses .mov. If we got a .mp4, transcode the container (no
    # re-encode — just copy streams into a .mov container).
    src_ext = src.suffix.lower().lstrip(".")
    if src_ext == "mov":
        # Direct copy
        video_dest = VIDEOS / f"{asset_uuid}.mov"
        VIDEOS.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, video_dest)
    else:
        # Remux to .mov via ffmpeg (no re-encode)
        VIDEOS.mkdir(parents=True, exist_ok=True)
        video_dest = VIDEOS / f"{asset_uuid}.mov"
        log(f"  remuxing {src.suffix} -> .mov (ffmpeg -c copy)")
        rc = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
             "-c", "copy", "-movflags", "+faststart", str(video_dest)],
            check=False,
        ).returncode
        if rc != 0 or not video_dest.exists():
            # Fall back to plain copy with .mov extension (Apple may still accept)
            log(f"  ffmpeg failed (rc={rc}), falling back to plain rename")
            shutil.copy(src, video_dest)

    THUMBS.mkdir(parents=True, exist_ok=True)
    thumb_dest = THUMBS / f"{asset_uuid}.png"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(video_dest),
         "-vf", "select=eq(n\\,30)", "-vframes", "1", str(thumb_dest)],
        check=False,
    )
    if not thumb_dest.exists():
        import base64
        thumb_dest.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        ))

    log(f"  asset UUID: {asset_uuid}")
    log(f"  video: {video_dest}")
    log(f"  thumb: {thumb_dest}")

    entries_backup = install_aerial(asset_uuid, video_dest, thumb_dest, "Whisky H7 Test")
    plist_backup = set_active_wallpaper(asset_uuid)

    log("killall WallpaperAgent + WallpaperAerialsExtension")
    for n in ("WallpaperAgent", "WallpaperAerialsExtension", "WallpaperAerial"):
        subprocess.run(["/usr/bin/killall", n], check=False, capture_output=True)
    log("waiting 8s for extension to re-read manifest + start rendering...")
    time.sleep(8)

    pids = subprocess.run(["/usr/bin/pgrep", "-i", "wallpaperaerial"],
                            capture_output=True, text=True).stdout.split()
    rendered_ours = False
    open_files = []
    for pid in pids:
        lsof = subprocess.run(["/usr/sbin/lsof", "-p", pid],
                                capture_output=True, text=True).stdout
        for line in lsof.split("\n"):
            if "/aerials/videos/" in line or "/Desktop Pictures/" in line:
                open_files.append(line.split()[-1] if line.split() else line)
                if asset_uuid in line:
                    rendered_ours = True

    log("=" * 60)
    if rendered_ours:
        log("HYPOTHESIS 7 VALIDATED — aerial impersonation works on Tahoe 26.5")
        log("recipe = .mov file + asset record + category record + Index.plist active node")
    else:
        log("HYPOTHESIS 7 REJECTED")
        log("WallpaperAerialsExtension open files:")
        for f in open_files[:5]:
            log(f"  - {f}")

    keep = os.environ.get("KEEP_TEST_STATE") == "1"
    if keep:
        log(f"KEEP_TEST_STATE=1 — leaving wallpaper active. Look at your desktop now.")
        log(f"Asset UUID for cleanup: {asset_uuid}")
        sys.exit(0 if rendered_ours else 1)

    # Restore
    ENTRIES_JSON.write_text(entries_backup.read_text())
    entries_backup.unlink()
    with open(plist_backup, "rb") as f:
        data = f.read()
    with open(INDEX_PLIST, "wb") as f:
        f.write(data)
    plist_backup.unlink()
    video_dest.unlink(missing_ok=True)
    thumb_dest.unlink(missing_ok=True)
    subprocess.run(["/usr/bin/killall", "WallpaperAgent"], check=False, capture_output=True)
    sys.exit(0 if rendered_ours else 1)


if __name__ == "__main__":
    main()
