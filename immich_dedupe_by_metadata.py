#!/usr/bin/env python3
"""
Written by Claude

immich_dedupe_by_metadata.py

Finds and removes low-resolution duplicate assets in an Immich library by
grouping assets on (dateTimeOriginal + GPS) rather than filename, then keeping
the highest-resolution asset per group and (optionally) deleting the rest.

Works entirely through the Immich REST API -- no database access needed.

USAGE
  # 1. Dry run first. Always. This writes a CSV report and deletes nothing.
  python3 immich_dedupe_by_metadata.py \
      --url https://immich.example.com --api-key YOUR_KEY

  # 2. Review dedupe_report.csv. Once you're happy, actually delete
  #    (assets go to Immich's trash, not permanently deleted):
  python3 immich_dedupe_by_metadata.py \
      --url https://immich.example.com --api-key YOUR_KEY --execute

  # 3. Permanently delete instead of trashing (skips trash entirely):
  python3 immich_dedupe_by_metadata.py \
      --url https://immich.example.com --api-key YOUR_KEY --execute --force

REQUIREMENTS
  pip install requests
"""

import argparse
import csv
import sys
import time
from collections import defaultdict
from datetime import datetime

import requests


def get_session(base_url: str, api_key: str) -> requests.Session:
    s = requests.Session()
    s.headers.update({"x-api-key": api_key, "Accept": "application/json"})
    s.base_url = base_url.rstrip("/")
    return s


def fetch_all_assets(session: requests.Session, asset_type: str, page_size: int = 1000):
    """Page through /api/search/metadata, yielding assets with exifInfo attached."""
    page = 1
    total_seen = 0
    while True:
        resp = session.post(
            f"{session.base_url}/api/search/metadata",
            json={"type": asset_type, "withExif": True, "page": page, "size": page_size},
        )
        resp.raise_for_status()
        data = resp.json()
        items = data.get("assets", {}).get("items", [])
        if not items:
            break
        for item in items:
            yield item
        total_seen += len(items)
        print(f"  fetched {total_seen} {asset_type} assets so far...", file=sys.stderr)

        next_page = data.get("assets", {}).get("nextPage")
        if not next_page:
            break
        page = int(next_page)


def round_coord(value, precision=4):
    """Round GPS coordinate to ~11m precision so tiny float drift doesn't split groups."""
    if value is None:
        return None
    return round(float(value), precision)


def group_key(asset: dict):
    exif = asset.get("exifInfo") or {}
    dt = exif.get("dateTimeOriginal")
    lat = round_coord(exif.get("latitude"))
    lon = round_coord(exif.get("longitude"))
    if dt is None:
        return None  # can't safely group assets with no timestamp
    # Normalize to the second; some assets store with/without timezone offset
    dt_norm = dt[:19] if isinstance(dt, str) else str(dt)
    return (dt_norm, lat, lon)


def resolution(asset: dict) -> int:
    exif = asset.get("exifInfo") or {}
    w = exif.get("exifImageWidth") or 0
    h = exif.get("exifImageHeight") or 0
    return int(w) * int(h)


def file_size(asset: dict) -> int:
    exif = asset.get("exifInfo") or {}
    return int(exif.get("fileSizeInByte") or 0)


def dimensions(asset: dict):
    exif = asset.get("exifInfo") or {}
    w = exif.get("exifImageWidth") or 0
    h = exif.get("exifImageHeight") or 0
    return int(w), int(h)


def aspect_ratio(asset: dict):
    w, h = dimensions(asset)
    if w == 0 or h == 0:
        return None
    return w / h


def aspect_matches(keeper: dict, candidate: dict, tolerance: float) -> bool:
    """True if the two assets' aspect ratios match within `tolerance` (fractional,
    e.g. 0.02 = 2%). Accounts for possible 90-degree rotation between the two
    (e.g. one stored portrait, one landscape, same physical photo)."""
    ar_k = aspect_ratio(keeper)
    ar_c = aspect_ratio(candidate)
    if ar_k is None or ar_c is None:
        return False
    diff_direct = abs(ar_k - ar_c) / ar_k
    diff_rotated = abs(ar_k - (1 / ar_c)) / ar_k
    return min(diff_direct, diff_rotated) <= tolerance


def find_duplicates(assets, ratio_threshold: float, max_dimension: int = None,
                     aspect_tolerance: float = None, min_keeper_dimension: int = None):
    """
    Group assets by (timestamp, gps). Within each group of size > 1, keep the
    highest-resolution asset and flag the rest as duplicates IF their
    resolution is below ratio_threshold of the keeper's resolution.
    Ties on resolution fall back to file size as the keeper.

    If max_dimension is set, a candidate is ONLY flagged when BOTH its width
    and height are <= max_dimension -- this is an absolute safety cap on top
    of the ratio check, so a smaller-but-still-large real photo never gets
    caught just because something bigger happens to sit in the same group.

    If aspect_tolerance is set (e.g. 0.02 for 2%), a candidate is ONLY flagged
    when its aspect ratio matches the keeper's within that tolerance (allowing
    for a 90-degree rotation). This filters out same-timestamp/GPS assets that
    are actually different shots (different framing) rather than a resize of
    the same image.

    If min_keeper_dimension is set, an entire group is skipped (nothing in it
    flagged) unless the keeper itself has BOTH width and height >=
    min_keeper_dimension. This avoids deleting "duplicates" of a group whose
    best available asset is itself low-res -- i.e. there's no trustworthy
    high-res original to keep, so don't delete anything from that group.
    """
    groups = defaultdict(list)
    ungrouped = 0
    for asset in assets:
        key = group_key(asset)
        if key is None:
            ungrouped += 1
            continue
        groups[key].append(asset)

    if ungrouped:
        print(f"  note: {ungrouped} assets had no dateTimeOriginal and were skipped "
              f"(never flagged as duplicates)", file=sys.stderr)

    to_delete = []
    kept_pairs = []  # (keeper, [dupes]) for the report

    for key, members in groups.items():
        if len(members) < 2:
            continue
        members.sort(key=lambda a: (resolution(a), file_size(a)), reverse=True)
        keeper = members[0]

        if min_keeper_dimension is not None:
            kw, kh = dimensions(keeper)
            if kw < min_keeper_dimension or kh < min_keeper_dimension:
                continue  # no trustworthy high-res original in this group -- skip entirely

        keeper_res = resolution(keeper) or 1
        dupes_here = []
        for candidate in members[1:]:
            cand_res = resolution(candidate)
            if cand_res == 0:
                continue  # no dimension data, don't guess -- skip
            if cand_res / keeper_res > ratio_threshold:
                continue  # not proportionally smaller enough
            if max_dimension is not None:
                cw, ch = dimensions(candidate)
                if cw > max_dimension or ch > max_dimension:
                    continue  # too big in absolute terms, don't touch it
            if aspect_tolerance is not None:
                if not aspect_matches(keeper, candidate, aspect_tolerance):
                    continue  # shape doesn't match the keeper -- probably a different photo
            dupes_here.append(candidate)
        if dupes_here:
            to_delete.extend(dupes_here)
            kept_pairs.append((keeper, dupes_here))

    return to_delete, kept_pairs


def write_report(kept_pairs, base_url: str, path="dedupe_report.csv"):
    base_url = base_url.rstrip("/")
    def asset_url(asset_id: str) -> str:
        return f"{base_url}/photos/{asset_id}"

    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "group_key",
            "keeper_id", "keeper_filename", "keeper_width", "keeper_height",
            "keeper_aspect", "keeper_bytes", "keeper_url",
            "dupe_id", "dupe_filename", "dupe_width", "dupe_height",
            "dupe_aspect", "dupe_bytes", "dupe_url",
        ])
        for keeper, dupes in kept_pairs:
            kw, kh = dimensions(keeper)
            k_ar = aspect_ratio(keeper)
            kbytes = file_size(keeper)
            for d in dupes:
                dw, dh = dimensions(d)
                d_ar = aspect_ratio(d)
                dbytes = file_size(d)
                w.writerow([
                    (d.get("exifInfo") or {}).get("dateTimeOriginal"),
                    keeper["id"], keeper.get("originalFileName"), kw, kh,
                    f"{k_ar:.3f}" if k_ar else "", kbytes, asset_url(keeper["id"]),
                    d["id"], d.get("originalFileName"), dw, dh,
                    f"{d_ar:.3f}" if d_ar else "", dbytes, asset_url(d["id"]),
                ])
    return path


def delete_assets(session: requests.Session, ids, force: bool, batch_size=1000):
    for i in range(0, len(ids), batch_size):
        batch = ids[i:i + batch_size]
        resp = session.delete(
            f"{session.base_url}/api/assets",
            json={"ids": batch, "force": force},
        )
        resp.raise_for_status()
        print(f"  deleted batch {i // batch_size + 1} "
              f"({len(batch)} assets, force={force})", file=sys.stderr)
        time.sleep(0.5)  # be polite to the job queue


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="Base Immich URL, e.g. https://immich.example.com")
    ap.add_argument("--api-key", required=True, help="Immich API key")
    ap.add_argument("--types", nargs="+", default=["IMAGE"], choices=["IMAGE", "VIDEO"],
                     help="Asset types to scan (default: IMAGE only)")
    ap.add_argument("--ratio-threshold", type=float, default=0.7,
                     help="An asset is flagged as a duplicate if its pixel area is below "
                          "this fraction of the largest asset in its group (default 0.7)")
    ap.add_argument("--max-dimension", type=int, default=None,
                     help="Absolute safety cap: only flag a candidate as a duplicate if "
                          "BOTH its width and height are <= this value, e.g. 400. "
                          "Combined with --ratio-threshold (both must pass).")
    ap.add_argument("--aspect-tolerance", type=float, default=None,
                     help="Only flag a candidate as a duplicate if its aspect ratio matches "
                          "the keeper's within this fraction, e.g. 0.02 for 2%% "
                          "(accounts for 90-degree rotation). Recommended: 0.02-0.05. "
                          "Off by default.")
    ap.add_argument("--min-keeper-dimension", type=int, default=None,
                     help="Skip an entire group (delete nothing from it) unless the asset "
                          "being kept has BOTH width and height >= this value. Protects "
                          "against deleting 'duplicates' of a group whose best asset is "
                          "itself low-res. Off by default.")
    ap.add_argument("--execute", action="store_true",
                     help="Actually delete. Without this flag, only a report is written.")
    ap.add_argument("--force", action="store_true",
                     help="Permanently delete instead of moving to trash (only with --execute)")
    ap.add_argument("--report", default="dedupe_report.csv", help="Path to write the CSV report")
    args = ap.parse_args()

    session = get_session(args.url, args.api_key)

    all_assets = []
    for t in args.types:
        print(f"Fetching {t} assets...", file=sys.stderr)
        all_assets.extend(fetch_all_assets(session, t))
    print(f"Total assets fetched: {len(all_assets)}", file=sys.stderr)

    to_delete, kept_pairs = find_duplicates(
        all_assets, args.ratio_threshold, args.max_dimension, args.aspect_tolerance,
        args.min_keeper_dimension)
    report_path = write_report(kept_pairs, args.url, args.report)

    total_bytes_reclaimed = sum(file_size(a) for a in to_delete)
    print(f"\nFound {len(to_delete)} likely low-res duplicates across "
          f"{len(kept_pairs)} groups.")
    print(f"Estimated space to reclaim: {total_bytes_reclaimed / (1024**3):.2f} GB")
    print(f"Report written to: {report_path}")

    if not args.execute:
        print("\nDry run only -- nothing deleted. Review the report, then re-run with --execute.")
        return

    if args.force:
        confirm = input(
            f"\nThis will PERMANENTLY delete {len(to_delete)} assets (no trash). "
            f"Type 'yes' to continue: "
        )
    else:
        confirm = input(
            f"\nThis will move {len(to_delete)} assets to Immich's trash. "
            f"Type 'yes' to continue: "
        )
    if confirm.strip().lower() != "yes":
        print("Aborted.")
        return

    ids = [a["id"] for a in to_delete]
    delete_assets(session, ids, force=args.force)
    print("Done. " + ("Permanently deleted." if args.force
          else "Moved to trash -- empty the trash in Immich when you're satisfied."))


if __name__ == "__main__":
    main()
