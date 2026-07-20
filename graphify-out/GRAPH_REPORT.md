# Graph Report - whisky-wallpaper  (2026-07-20)

## Corpus Check
- 14 files · ~39,818 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 137 nodes · 195 edges · 15 communities (9 shown, 6 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 3 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `dd16ed15`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]

## God Nodes (most connected - your core abstractions)
1. `AppDelegate` - 20 edges
2. `AerialInstaller` - 15 edges
3. `Whisky Wallpaper` - 13 edges
4. `WallpaperPlayer` - 10 edges
5. `PlaylistManager` - 6 edges
6. `update_index_plist()` - 5 edges
7. `InstallerError` - 5 edges
8. `SettingsManager` - 5 edges
9. `Security policy` - 5 edges
10. `log()` - 4 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Communities (15 total, 6 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.09
Nodes (22): Architecture, Build from source, code:bash (git clone https://github.com/ForceAI-KW/whisky-wallpaper.git), code:block2 (✨  Now playing: Astronaut Facing Black Hole), code:block3 (WhiskyWallpaper/), code:bash (./scripts/uninstall.sh), Credits, Install (+14 more)

### Community 1 - "Community 1"
Cohesion: 0.2
Nodes (3): NSApplicationDelegate, NSObject, AppDelegate

### Community 4 - "Community 4"
Cohesion: 0.25
Nodes (7): Codable, Error, InstallerError, entriesJsonMalformed, indexPlistMalformed, thumbnailGenerationFailed, ManagedAerial

### Community 5 - "Community 5"
Cohesion: 0.25
Nodes (6): Architecture (7 Swift files), Build, code:bash (xcodebuild -project WhiskyWallpaper.xcodeproj -scheme Whisky), Standing rules from global config, v2 architecture (2026-05-28), What this project is

### Community 6 - "Community 6"
Cohesion: 0.57
Nodes (6): add_aerial_entry(), build_aerial_choice(), log(), main(), Update SystemDefault, Spaces.Default, and the per-display + per-Space     overri, update_index_plist()

### Community 7 - "Community 7"
Cohesion: 0.38
Nodes (3): NSView, WallpaperHostView, WallpaperWindowController

### Community 8 - "Community 8"
Cohesion: 0.29
Nodes (6): code:bash (# Confirm no network frameworks are linked), How to verify, Reporting a security issue, Security policy, What it doesn't do, What Whisky Wallpaper touches on your system

### Community 9 - "Community 9"
Cohesion: 0.67
Nodes (5): install_aerial(), log(), main(), Add asset record + category record with representativeAssetID., set_active_wallpaper()

### Community 12 - "Community 12"
Cohesion: 0.6
Nodes (4): cleanup_and_exit(), log(), main(), Always restore original state, even on success — so we don't pollute     the use

## Knowledge Gaps
- **30 isolated node(s):** `Always restore original state, even on success — so we don't pollute     the use`, `Update SystemDefault, Spaces.Default, and the per-display + per-Space     overri`, `Add asset record + category record with representativeAssetID.`, `indexPlistMalformed`, `entriesJsonMalformed` (+25 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `WallpaperPlayer` connect `Community 3` to `Community 1`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **Why does `WallpaperWindowController` connect `Community 7` to `Community 1`?**
  _High betweenness centrality (0.024) - this node is a cross-community bridge._
- **What connects `Always restore original state, even on success — so we don't pollute     the use`, `Update SystemDefault, Spaces.Default, and the per-display + per-Space     overri`, `Add asset record + category record with representativeAssetID.` to the rest of the system?**
  _30 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.09 - nodes in this community are weakly interconnected._