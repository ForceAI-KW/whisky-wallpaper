#!/usr/bin/env python3
"""
Hypothesis 6 test: the active wallpaper on Tahoe 26.5 is configured in
Index.plist's `SystemDefault.Linked.Content.Choices` and
`Spaces.Default.Linked.Content.Choices`, NOT in `Displays[*].Desktop.Content`.

We've been editing `Displays[*]` and missing the actual source-of-truth
nodes. This script updates ALL four locations.

Usage:
    python3 scripts/test-h6-system-default.py <video.mp4>

KEEP_TEST_STATE=1 — leave the test wallpaper in place (so you can SEE it)
                    instead of cleaning up.
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

APPLE_AERIAL_CATEGORY = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
APPLE_TAHOE_SUBCATEGORY = "0DC99DD8-3386-4D1E-8878-C43E97EB710A"


def log(msg):
    print(f"[h6-test] {msg}", flush=True)


def build_aerial_choice(asset_uuid):
    configuration_data = plistlib.dumps({"assetID": asset_uuid}, fmt=plistlib.FMT_BINARY)
    return {
        "Configuration": configuration_data,
        "Files": [],
        "Provider": "com.apple.wallpaper.choice.aerials",
    }


def update_index_plist(asset_uuid):
    """Update SystemDefault, Spaces.Default, and the per-display + per-Space
    overrides — the four places that can hold an active-wallpaper choice."""
    with open(INDEX_PLIST, "rb") as f:
        root = plistlib.load(f, fmt=plistlib.FMT_BINARY)
    backup = INDEX_PLIST.with_suffix(".plist.h6backup")
    with open(backup, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)

    now = datetime.now()
    choice = build_aerial_choice(asset_uuid)

    def write_content(parent, slot_keys):
        """Given a dict that holds a 'Content' subtree (under e.g. 'Linked',
        'Desktop', 'Idle'), set its Choices to point at our aerial."""
        content = parent.get("Content") or {}
        content["Choices"] = [choice]
        content["Shuffle"] = "$null"
        parent["Content"] = content
        parent["LastSet"] = now
        parent["LastUse"] = now

    # 1. SystemDefault.Linked
    sysdef = root.get("SystemDefault") or {}
    sysdef["Type"] = "linked"
    linked = sysdef.get("Linked") or {}
    write_content(linked, ["Content"])
    sysdef["Linked"] = linked
    root["SystemDefault"] = sysdef
    log(f"  updated SystemDefault.Linked")

    # 2. Spaces.Default.Linked  +  Spaces.Displays.<uuid>.Desktop+Idle
    spaces = root.get("Spaces") or {}
    sp_default = spaces.get("Default") or {}
    sp_default["Type"] = "linked"
    sp_default_linked = sp_default.get("Linked") or {}
    write_content(sp_default_linked, ["Content"])
    sp_default["Linked"] = sp_default_linked
    spaces["Default"] = sp_default
    log(f"  updated Spaces.Default.Linked")

    sp_displays = spaces.get("Displays") or {}
    for d_id, d in sp_displays.items():
        d["Type"] = "linked"  # inherit from Spaces.Default instead of individual
        # Wipe per-display overrides so it inherits cleanly
        d.pop("Desktop", None)
        d.pop("Idle", None)
        sp_displays[d_id] = d
    spaces["Displays"] = sp_displays
    root["Spaces"] = spaces
    log(f"  set {len(sp_displays)} Spaces.Displays to Type=linked")

    # 3. AllSpacesAndDisplays — may be a sentinel string ($null) or missing.
    # Only overwrite if it's already a structured dict; replacing a $null
    # with a populated dict can mark the file as "user overrode the system"
    # which is also fine for our test.
    asd = root.get("AllSpacesAndDisplays")
    if isinstance(asd, dict):
        asd["Type"] = "linked"
        asd_linked = asd.get("Linked") or {}
        write_content(asd_linked, ["Content"])
        asd["Linked"] = asd_linked
        root["AllSpacesAndDisplays"] = asd
        log(f"  updated AllSpacesAndDisplays.Linked")
    else:
        # Build a fresh one
        new_asd = {"Type": "linked", "Linked": {}}
        write_content(new_asd["Linked"], ["Content"])
        root["AllSpacesAndDisplays"] = new_asd
        log(f"  created AllSpacesAndDisplays (was {type(asd).__name__})")

    # 4. Top-level Displays (legacy / fallback)
    displays = root.get("Displays", {})
    for d_id, d in displays.items():
        d["Type"] = "linked"
        d.pop("Desktop", None)
        d.pop("Idle", None)
        displays[d_id] = d
    root["Displays"] = displays
    log(f"  set {len(displays)} Displays to Type=linked")

    with open(INDEX_PLIST, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
    log(f"  Index.plist written; backup at {backup.name}")
    return backup


def add_aerial_entry(asset_uuid, video_url, thumb_url, name):
    entries = json.loads(ENTRIES_JSON.read_text())
    backup = ENTRIES_JSON.with_suffix(".json.h6backup")
    backup.write_text(ENTRIES_JSON.read_text())

    shot_id = "H6_" + asset_uuid.replace("-", "_")
    entry = {
        "id": asset_uuid,
        "accessibilityLabel": name,
        "localizedNameKey": name,
        "shotID": shot_id,
        "showInTopLevel": True,
        "includeInShuffle": True,
        "preferredOrder": 0,
        "previewImage": f"file://{thumb_url}",
        "url-4K-SDR-240FPS": f"file://{video_url}",
        "subcategories": [APPLE_TAHOE_SUBCATEGORY],
        "categories": [APPLE_AERIAL_CATEGORY],
        "pointsOfInterest": {"0": f"{shot_id}_0"},
    }
    entries["assets"].append(entry)
    ENTRIES_JSON.write_text(json.dumps(entries, indent=2, sort_keys=True))
    log(f"  appended asset record to entries.json")
    return backup


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    src_video = Path(sys.argv[1])
    if not src_video.exists():
        log(f"FATAL: video not found: {src_video}")
        sys.exit(2)

    asset_uuid = str(uuid.uuid4()).upper()
    ext = src_video.suffix.lower().lstrip(".") or "mp4"
    if ext not in {"mp4", "mov", "m4v"}:
        ext = "mp4"
    video_dest = VIDEOS / f"{asset_uuid}.{ext}"
    thumb_dest = THUMBS / f"{asset_uuid}.png"

    log(f"asset UUID: {asset_uuid}")
    VIDEOS.mkdir(parents=True, exist_ok=True)
    THUMBS.mkdir(parents=True, exist_ok=True)
    shutil.copy(src_video, video_dest)
    log(f"  copied video -> {video_dest.name}")

    # Thumbnail (fallback to 1x1 PNG if no ffmpeg)
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(video_dest),
                         "-vf", "select=eq(n\\,0)", "-vframes", "1", str(thumb_dest)],
                        check=False)
    if not thumb_dest.exists():
        import base64
        thumb_dest.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        ))

    entries_backup = add_aerial_entry(asset_uuid, video_dest, thumb_dest, "H6 Test")
    plist_backup = update_index_plist(asset_uuid)

    log("killall WallpaperAgent + WallpaperAerialsExtension + WallpaperKitDefaultRenderer")
    for name in ("WallpaperAgent", "WallpaperAerial", "WallpaperAerialsExtension",
                  "WallpaperKitDefaultRenderer", "idleassetsd"):
        subprocess.run(["/usr/bin/killall", name], check=False, capture_output=True)

    log("waiting 7s for re-spawn...")
    time.sleep(7)

    pids = subprocess.run(["/usr/bin/pgrep", "-i", "wallpaperaerial"],
                            capture_output=True, text=True).stdout.split()
    log(f"WallpaperAerial PIDs: {pids or 'NONE'}")

    rendered_ours = False
    diagnostics = []
    for pid in pids:
        lsof = subprocess.run(["/usr/sbin/lsof", "-p", pid],
                                capture_output=True, text=True).stdout
        if asset_uuid in lsof or video_dest.name in lsof:
            rendered_ours = True
            log(f"  PID {pid} has OUR video open")
            break
        for line in lsof.split("\n"):
            if ".mov" in line or ".mp4" in line:
                parts = line.split()
                if parts:
                    diagnostics.append(parts[-1])

    log("=" * 60)
    if rendered_ours:
        log("HYPOTHESIS 6 VALIDATED — SystemDefault.Linked was the missing piece")
    else:
        log("HYPOTHESIS 6 REJECTED — still falling back. Files extension has open:")
        for d in diagnostics[:5]:
            log(f"  - {d}")
        log("next: hypothesis 2 (https URL via localhost) or check entries.json reachability")

    keep = os.environ.get("KEEP_TEST_STATE") == "1"
    if keep:
        log(f"KEEP_TEST_STATE=1 — leaving asset in place. To clean up:")
        log(f"  python3 scripts/cleanup-test-aerial.py {asset_uuid}")
        sys.exit(0 if rendered_ours else 1)

    # Restore
    if entries_backup.exists():
        ENTRIES_JSON.write_text(entries_backup.read_text())
        entries_backup.unlink()
    if plist_backup.exists():
        with open(plist_backup, "rb") as f:
            data = f.read()
        with open(INDEX_PLIST, "wb") as f:
            f.write(data)
        plist_backup.unlink()
    video_dest.unlink(missing_ok=True)
    thumb_dest.unlink(missing_ok=True)
    subprocess.run(["/usr/bin/killall", "WallpaperAgent"], check=False, capture_output=True)
    subprocess.run(["/usr/bin/killall", "WallpaperAerialsExtension"], check=False, capture_output=True)
    log("cleanup done")
    sys.exit(0 if rendered_ours else 1)


if __name__ == "__main__":
    main()
