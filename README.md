# Picker

A native macOS 26+ SwiftUI app for reviewing similar photos in Apple Photos. All analysis and review state stay on your Mac. No account or photo upload is required. Signed release builds use Sparkle for optional app updates.

## Distribution

GitHub builds universal macOS releases, signs and notarizes them, and publishes a signed Sparkle update feed. See [release setup and publishing](RELEASE.md) for GitHub secrets and the release workflow. Local development builds have updates disabled.

## Run

Open `Picker.xcodeproj` in Xcode 26 or later, choose the **Picker** scheme and **My Mac**, and run. The project uses local ad-hoc signing. Click **Connect to Photos** and allow full Photos access. Picker automatically scans your Apple Photos library through PhotoKit; you do not select or import individual files.

The development build is at `build/Build/Products/Debug/Picker.app`.

```sh
xcodebuild -project Picker.xcodeproj -scheme Picker \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build

xcodebuild -project Picker.xcodeproj -scheme Picker \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

`project.yml` is the XcodeGen source. The generated Xcode project is included, so XcodeGen is only needed if you change the project configuration.

## Review photos

1. Check the library. Unchanged time windows appear immediately from the grouping cache. New groups become reviewable once their ten-minute grouping window has closed; you can keep, remove, and reset while other photos are still being checked. Photos are compared using Vision feature prints, with a conservative distance threshold and a ten-minute capture window. Groups compare against a representative photo to avoid long chains of increasingly unrelated images.
2. Choose a group in the native three-column browser. The suggested photo opens in a large preview above a horizontal thumbnail strip. Click a thumbnail or use the arrow keys to compare alternatives. A **blue outline** shows the highlighted photo, an orange **Recommended** badge marks the suggestion, and a **green checkmark** marks your chosen keepers. Once you choose a keeper, the remaining photos show active red crosses; you can still keep any of them. Each photo has a paired tick/cross control, with green ticks for keepers, red crosses for removals, and neutral controls before a decision. A recommendation never chooses a keeper automatically.
3. Press Return or click a tick to choose a keeper. The other photos immediately get red crosses and appear in **Pending**. You can keep multiple photos; ticking another removes it from Pending. Crossing a neutral photo marks just that photo for deletion and keeps its alternatives. The last keeper is protected; **Reset** returns the group to neutral and removes its photos from Pending.
4. **Apply** asks to confirm deletion of only the current group’s crossed photos. After successful deletion the group moves to **History** and the next group opens. Other pending groups are untouched. Cancel leaves your choices in Pending. Keeping everything and clicking Apply resolves the group without deletion. Moving to the next group leaves the current group and its choices available for later review.
5. The sidebar contains **Similar Photos** (unprocessed groups), **Pending** (a grid of every crossed photo), **History** (processed groups), and **Screenshots**.
6. In Pending, **Delete All N Pending Photos…** explicitly acts on the entire pending grid, after confirmation. Keep a pending photo to remove it immediately, or use Review Group to change its choices in Similar Photos. History retains completed deletions, including multiple keepers, across library refreshes. Reset reopens an undeleted group. Recovery of deleted images is through Recently Deleted in Apple Photos.

| Key | Action |
| --- | --- |
| Left / Right | Highlight the previous / next photo |
| Space | Hide / show thumbnails |
| Return | Choose highlighted photo as a keeper; retain other keepers |
| Command–Return | Apply only the current group |
| Command–Down / Up | Move to next / previous group |
| Escape | Restore the thumbnail strip |

The large preview is always visible. Its corner icon or Space hides the thumbnails to give the photo more room; press again to restore them. Reduced Motion is respected. The same shortcuts work in the expanded view. Review shortcuts are suspended while a sheet is open.

The footer shows the library’s total photo count, detected group count, potential removals (one keeper per group), and the Pending count. Potential removals include skipped and reviewed groups and are independent of your selections.

## Local analysis and safeguards

- Analysis (768-pixel target) and thumbnail (600-pixel target) requests disable network access. Picker never downloads library images for analysis, and does not save preview image files to its own cache. Large previews request a rendition sized for the visible window, capped at 2,560 pixels on the long edge. Picker uses local data by default. If a better preview needs iCloud, **Download This Photo** is the explicit opt-in for that one visible photo; merely opening or navigating groups never authorizes a download. It never requests maximum-size originals for routine previews. Photos controls the underlying download and may still fetch an original to produce the requested rendition. The preview shows download progress, supports retry, and cancels its outstanding requests when you switch photos or close it. Cloud-only or otherwise unreadable images are skipped; download originals in Photos and scan again to include them.
- Vision revision 2 feature prints and image aesthetics run off the main actor. Suggestions use aesthetics with small preferences for favorites and resolution. Suggestions are fallible and always require your selection.
- Feature prints, metadata, and groups are cached as `analysis.json`; current choices are stored in `decisions.json`; completed review history is stored in `history.json`, all under the sandbox’s Application Support/Picker directory. Image files are not copied to this cache. Feature analysis resumes from saved checkpoints on a later scan. Completed time windows are also cached using a stable fingerprint of every asset and its metadata, so an unchanged window requires no image requests, Vision calls, or similarity comparisons. On the first launch after this cache upgrade, groups are rebuilt using existing Vision features. Unavailable results are retained too; choose **Retry Unavailable Photos** in the scan menu beside “Analysis on this Mac” after downloading additional originals.
- Scanning can be stopped without losing completed analysis. All published groups are complete and editable during background scanning. Progress distinguishes checked photos, reused analysis, and newly analyzed images. Opening either deletion confirmation or Screenshots pauses and checkpoints the scan before presenting a stable review list; cancelling the confirmation or closing the sheet resumes pending work. Incoming scan results preserve the highlighted photo and any choices made on unchanged groups.
- Decisions are retained only for unchanged groups. Library changes trigger a refresh or defer it until the queue closes. Immediately before deletion, every group member—including keepers—is fetched again and checked for changes. A missing or edited member blocks that deletion attempt. The list title, group navigation, date, keeper count, Reset, and Apply share one compact native window toolbar. Each column supplies its own toolbar content. Group arrows and the date use the detail column’s leading toolbar placement, with a flexible spacer before Reset and Apply at the right. The system preserves these positions when the sidebar collapses or the window resizes. There is no separate header row or manually calculated toolbar width. The thumbnail toggle has its own icon in the photo’s upper-right corner. Scan controls sit beside “Analysis on this Mac” in the sidebar. Decision controls remain with each thumbnail (or next to the expanded photo). The bottom footer only reports progress and totals, and is laid out separately so it cannot overlap those controls.
- The app has the Photos-library sandbox entitlement. Preview downloads are handled by Apple Photos through PhotoKit; Picker has no custom networking service.

## Current scope

This first version analyzes still images, including the still component of Live Photos. Deleting a Live Photo deletes the entire asset. It does not compare videos, play Live Photo motion, compare RAW originals, or find lookalikes taken more than ten minutes apart. The similarity threshold is intentionally fixed for this first version and has not been calibrated against your library. First scans of large libraries can take time; subsequent scans reuse cached features.

## Validation

The app builds and launches on the development Mac. Tests cover explicit-keeper requirements, multiple keepers, skipping, keeping everything, changed group membership, edits invalidating decisions, decision serialization, highlight/recommendation/keeper separation, and preview navigation. A Vision integration test checks feature generation, aesthetics, and secure feature-print cache round-tripping.

Workflow tests also cover group-scoped Apply, immediate Pending updates, confirmation cancellation, separate group and whole-list deletion scopes, keep-all decisions, reset, restoring pending photos, persistent deletion history, multiple keepers surviving a rescan, and invalidation after library changes.

Actual PhotoKit deletion must be validated manually using disposable photos in a test library. Development validation does not delete or alter your photos.

## Screenshot archive

Choose **Screenshots** in the sidebar to see images Photos classifies as screenshots. All are selected initially; deselect any you want to leave in the library. **Export & Delete…** first asks for a destination folder. Picker creates a unique subfolder and exports all PhotoKit resources for each selected asset, including originals and any edited or adjustment resources. Apple Photos downloads cloud resources as needed.

A JSON manifest maps each asset to its exported files, creation date, and SHA-256 checksums. The files must all export successfully before the separate **Delete Exported Screenshots…** action becomes available. Before deletion, Picker rechecks every exported file’s size and checksum and verifies that the library assets have not changed. Errors or cancellation leave Photos untouched and preserve completed exports. You can also close the sheet after export to keep both copies. Deletion syncs through iCloud Photos and moves the assets to Recently Deleted.

The destination is granted through the native folder chooser and the user-selected-file sandbox entitlement. Imported Mac screenshots that Photos does not classify as screenshots are not included. The export is an archive of image resources and metadata, not a restorable Photos-library backup (albums, sharing, and library history are not recreated). Real-library export and deletion require manual testing with disposable screenshots; automated tests verify manifest round-tripping and that missing, modified, or empty files block verification.
