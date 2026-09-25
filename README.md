# Miscellaneous mods, patches, scripts, etc.

Stuff I may or may not use. Good to have around.

---

## remove_discord_top_bar.css

Removes discord's top bar/title bar thing and some other stuff.

---

### quest_network_interface.sh

A port of [UbootVRC/Wired-Steam-Link-VR](https://github.com/UbootVRC/) for linux. Lets you do wired steam vr link. The option to let apps connect over usb under the link category in settings must be disabled.

---

### immich_dedupe_by_metadata.py

Oops! Uploaded all the thumbnails from a backup to your immich library? I would never!

Usage: `python immich_dedupe_by_metadata.py --url <immich_url> --api-key <api_key> --max-dimension 400 --aspect-tolerance 0.02 --min-keeper-dimension 800 --execute`

Options:
```
--url
--api-key
--types, default=["IMAGE"], choices=["IMAGE", "VIDEO"], Asset types to scan (default: IMAGE only)
--ratio-threshold, default=0.7, An asset is flagged as a duplicate if its pixel area is below this fraction of the largest asset in its group
--max-dimension, default=None, Absolute safety cap: only flag a candidate as a duplicate if BOTH its width and height are <= this value, e.g. 400. Combined with --ratio-threshold (both must pass).
--aspect-tolerance, default=None, Only flag a candidate as a duplicate if its aspect ratio matches the keeper's within this fraction, e.g. 0.02 for 2%% (accounts for 90-degree rotation). Recommended: 0.02-0.05. Off by default.
--execute, Actually delete. Without this flag, only a report is written.
--force, Permanently delete instead of moving to trash.
--report, default="dedupe_report.csv"
```
