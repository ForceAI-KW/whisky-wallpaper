#!/usr/bin/env python3
"""
Hypothesis 4 test: install our video as an aerial USING Apple's existing
category UUIDs instead of synthetic ones. If WallpaperAerialsExtension
filters out assets whose categories[] entries aren't real macOS catalog
UUIDs, this should be the fix.

Runs in isolation — does not depend on the Whisky Wallpaper app build.
Cleans up automatically at end.

Usage:
    python3 scripts/test-h4-apple-category.py <path-to-test-video.mp4>

Outputs:
    - exit 0 if WallpaperAerialsExtension opens our file
    - exit 1 if it opens Apple's default (Tahoe Day) instead
    - exit 2 on setup error
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

SUPPORT = Path.home() / "Library/Application Support/com.apple.wallpaper"
AERIALS = SUPPORT / "aerials"
VIDEOS = AERIALS / "videos"
THUMBS = AERIALS / "thumbnails"
ENTRIES_JSON = AERIALS / "manifest" / "entries.json"
INDEX_PLIST = SUPPORT / "Store" / "Index.plist"

# Apple's "Aerial" category UUID + "Tahoe" subcategory UUID, extracted
# from entries.json. These are guaranteed to be in categories[] so the
# extension's category-membership check passes.
APPLE_AERIAL_CATEGORY = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
APPLE_TAHOE_SUBCATEGORY = "0DC99DD8-3386-4D1E-8878-C43E97EB710A"

def log(msg):
    print(f"[h4-test] {msg}", flush=True)

def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    src_video = Path(sys.argv[1])
    if not src_video.exists():
        log(f"video not found: {src_video}")
        sys.exit(2)

    test_uuid = str(uuid.uuid4()).upper()
    ext = src_video.suffix.lower().lstrip(".")
    if ext not in {"mp4", "mov", "m4v"}:
        ext = "mp4"
    video_dest = VIDEOS / f"{test_uuid}.{ext}"
    thumb_dest = THUMBS / f"{test_uuid}.png"

    log(f"test UUID: {test_uuid}")
    log(f"video: {src_video} -> {video_dest}")

    # 1. Copy video
    VIDEOS.mkdir(parents=True, exist_ok=True)
    THUMBS.mkdir(parents=True, exist_ok=True)
    shutil.copy(src_video, video_dest)

    # 2. Generate thumbnail via ffmpeg if available, else a 1x1 PNG.
    if shutil.which("ffmpeg"):
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(video_dest),
             "-vf", "select=eq(n\\,0)", "-vframes", "1", str(thumb_dest)],
            check=False,
        )
    if not thumb_dest.exists():
        # 1x1 transparent PNG fallback
        import base64
        thumb_dest.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        ))
    log(f"thumbnail: {thumb_dest} ({thumb_dest.stat().st_size} B)")

    # 3. Add entry to entries.json
    entries = json.loads(ENTRIES_JSON.read_text())
    backup = ENTRIES_JSON.with_suffix(".json.h4backup")
    backup.write_text(json.dumps(entries))
    log(f"backed up entries.json to {backup.name}")

    shot_id = "H4_" + test_uuid.replace("-", "_")
    new_entry = {
        "id": test_uuid,
        "accessibilityLabel": "H4 Test",
        "localizedNameKey": "H4 Test",
        "shotID": shot_id,
        "showInTopLevel": True,
        "includeInShuffle": True,
        "preferredOrder": 0,
        "previewImage": f"file://{thumb_dest}",
        "url-4K-SDR-240FPS": f"file://{video_dest}",
        # THE KEY DIFFERENCE — use Apple's existing category UUIDs:
        "subcategories": [APPLE_TAHOE_SUBCATEGORY],
        "categories": [APPLE_AERIAL_CATEGORY],
        "pointsOfInterest": {"0": f"{shot_id}_0"},
    }
    entries["assets"].append(new_entry)
    ENTRIES_JSON.write_text(json.dumps(entries, indent=2, sort_keys=True))
    log(f"added asset record with categories={APPLE_AERIAL_CATEGORY}")

    # 4. Edit Index.plist — set Desktop + Idle on every display to our UUID
    with open(INDEX_PLIST, "rb") as f:
        root = plistlib.load(f, fmt=plistlib.FMT_BINARY)
    plist_backup = INDEX_PLIST.with_suffix(".plist.h4backup")
    with open(plist_backup, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
    log(f"backed up Index.plist to {plist_backup.name}")

    configuration_data = plistlib.dumps({"assetID": test_uuid}, fmt=plistlib.FMT_BINARY)
    aerial_choice = {
        "Configuration": configuration_data,
        "Files": [],
        "Provider": "com.apple.wallpaper.choice.aerials",
    }

    from datetime import datetime
    now = datetime.now()
    displays = root.get("Displays", {})
    touched = 0
    for display_id, display in displays.items():
        for slot in ("Desktop", "Idle"):
            slot_dict = display.get(slot) or {}
            content = slot_dict.get("Content") or {}
            content["Choices"] = [aerial_choice]
            content["Shuffle"] = "$null"
            slot_dict["Content"] = content
            slot_dict["LastSet"] = now
            slot_dict["LastUse"] = now
            display[slot] = slot_dict
        touched += 1
    root["Displays"] = displays

    with open(INDEX_PLIST, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
    log(f"updated {touched} display(s) in Index.plist")

    # 5. Restart the wallpaper agents
    for name in ("WallpaperAgent", "WallpaperAerial", "WallpaperAerialsExtension"):
        subprocess.run(["/usr/bin/killall", name], check=False, capture_output=True)
    log("killall sent; waiting 6s for re-spawn...")
    time.sleep(6)

    # 6. Verify: does WallpaperAerialsExtension have OUR file open?
    pid_out = subprocess.run(
        ["/usr/bin/pgrep", "-i", "wallpaperaerial"],
        capture_output=True, text=True,
    )
    pids = [p.strip() for p in pid_out.stdout.split("\n") if p.strip()]
    log(f"WallpaperAerial(s) PIDs: {pids or 'NONE'}")

    if not pids:
        log("FAIL — no WallpaperAerialsExtension running; check Console.app")
        return cleanup_and_exit(test_uuid, video_dest, thumb_dest, backup, plist_backup, 1)

    rendered_ours = False
    for pid in pids:
        lsof = subprocess.run(
            ["/usr/sbin/lsof", "-p", pid],
            capture_output=True, text=True,
        )
        # We want to see our UUID's mp4 OR our test_uuid in the open files
        if test_uuid in lsof.stdout or video_dest.name in lsof.stdout:
            rendered_ours = True
            log(f"PASS — PID {pid} has our video open")
            break
        # Diagnostic: what IS it playing instead?
        for line in lsof.stdout.split("\n"):
            if ".mov" in line or ".mp4" in line:
                log(f"  PID {pid} open: {line.split()[-1] if line.split() else line}")

    log("=" * 60)
    if rendered_ours:
        log("HYPOTHESIS 4 VALIDATED — Apple's category UUID fixes the silent skip")
        return cleanup_and_exit(test_uuid, video_dest, thumb_dest, backup, plist_backup, 0)
    log("HYPOTHESIS 4 REJECTED — extension still ignores our asset")
    log("next: try hypothesis 2 (localhost https URL)")
    return cleanup_and_exit(test_uuid, video_dest, thumb_dest, backup, plist_backup, 1)


def cleanup_and_exit(test_uuid, video_dest, thumb_dest, entries_backup, plist_backup, code):
    """Always restore original state, even on success — so we don't pollute
    the user's wallpaper. The test is verification only."""
    keep = os.environ.get("KEEP_TEST_STATE") == "1"
    if keep:
        print(f"[h4-test] KEEP_TEST_STATE=1 set — leaving test entry in place")
        print(f"[h4-test]   video: {video_dest}")
        print(f"[h4-test]   to remove: python3 scripts/test-h4-apple-category.py --cleanup {test_uuid}")
        sys.exit(code)

    # Restore entries.json + Index.plist from backups
    if entries_backup.exists():
        ENTRIES_JSON.write_text(entries_backup.read_text())
        entries_backup.unlink()
    if plist_backup.exists():
        with open(plist_backup, "rb") as f:
            data = f.read()
        with open(INDEX_PLIST, "wb") as f:
            f.write(data)
        plist_backup.unlink()
    if video_dest.exists():
        video_dest.unlink()
    if thumb_dest.exists():
        thumb_dest.unlink()
    subprocess.run(["/usr/bin/killall", "WallpaperAgent"], check=False, capture_output=True)
    subprocess.run(["/usr/bin/killall", "WallpaperAerialsExtension"], check=False, capture_output=True)
    print(f"[h4-test] cleanup done — original wallpaper state restored")
    sys.exit(code)


if __name__ == "__main__":
    main()
