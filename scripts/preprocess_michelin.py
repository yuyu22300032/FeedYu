#!/usr/bin/env python3
"""Regenerate FeedYu's bundled Michelin data.

Outputs (written in place, relative to the repo root):
  FeedYu/Resources/michelin.csv          current guide, ALL award tiers,
                                         reduced columns, price normalized
  FeedYu/Resources/michelin_history.csv  per-place years-on-list overlay:
                                         Current=1 rows carry Years for places
                                         on the current list; Current=0 rows
                                         are former places with full data from
                                         their last appearance

Source: https://github.com/ngshiheng/michelin-my-maps (MIT). The current CSV
comes from main; history comes from the latest commit of each calendar year
(2022+) touching the data file, via the GitHub API (no auth needed).
Downloads are cached in .michelin-cache/ (gitignored) — delete it to force
re-download.

Notes:
- 2022–2023 snapshots only tracked stars + Bib Gourmand, so Selected
  restaurants have year coverage from 2024 onward.
- Clustering key: normalized name + coordinates within 500 m (mirrors the
  app-side overlay matching in MichelinDataSource.applyHistoryOverlay).
"""

import csv
import json
import math
import sys
import unicodedata
import urllib.request
from collections import defaultdict
from datetime import date
from pathlib import Path

REPO = "ngshiheng/michelin-my-maps"
DATA_PATH = "data/michelin_my_maps.csv"
FIRST_YEAR = 2022
AWARDS = {"1 Star", "2 Stars", "3 Stars", "Bib Gourmand", "Selected Restaurants"}
OUT_COLS = ["Name", "Address", "Location", "Price", "Cuisine",
            "Longitude", "Latitude", "Url", "Award", "Description"]

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".michelin-cache"
RESOURCES = ROOT / "FeedYu" / "Resources"


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "FeedYu-preprocess"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def yearly_commits() -> dict[int, str]:
    """Latest commit sha per calendar year touching the data file."""
    shas: dict[int, str] = {}
    page = 1
    while page <= 5:
        url = (f"https://api.github.com/repos/{REPO}/commits"
               f"?path={DATA_PATH}&per_page=100&page={page}")
        commits = json.loads(fetch(url))
        if not commits:
            break
        for commit in commits:  # newest first
            year = int(commit["commit"]["committer"]["date"][:4])
            if year >= FIRST_YEAR:
                shas.setdefault(year, commit["sha"])
        page += 1
    current_year = date.today().year
    shas.pop(current_year, None)  # current year is covered by main
    return shas


def cached_csv(name: str, url: str) -> list[dict]:
    path = CACHE / name
    if not path.exists():
        print(f"downloading {name} …")
        path.write_bytes(fetch(url))
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def norm(name: str) -> str:
    decomposed = unicodedata.normalize("NFD", name)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return "".join(c for c in stripped.lower() if c.isalnum())


def dist_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def price_band(price: str) -> str:
    price = (price or "").strip()
    return "$" * min(4, max(1, len(price))) if price else ""


def compress_years(years) -> str:
    ordered = sorted(years)
    runs, start, prev = [], ordered[0], ordered[0]
    for year in ordered[1:]:
        if year == prev + 1:
            prev = year
        else:
            runs.append((start, prev))
            start = prev = year
    runs.append((start, prev))
    return ", ".join(f"{a}–{b}" if a != b else f"{a}" for a, b in runs)


def reduced_row(row: dict) -> dict:
    out = {col: row.get(col, "") for col in OUT_COLS}
    out["Price"] = price_band(out["Price"])
    out["Description"] = (out.get("Description") or "")[:200]
    return out


def main() -> None:
    CACHE.mkdir(exist_ok=True)
    current_year = date.today().year

    snapshots = [(year, f"michelin_{year}.csv",
                  f"https://raw.githubusercontent.com/{REPO}/{sha}/{DATA_PATH}")
                 for year, sha in sorted(yearly_commits().items())]
    snapshots.append((current_year, "michelin_current.csv",
                      f"https://raw.githubusercontent.com/{REPO}/main/{DATA_PATH}"))

    # clusters[normalized name] = [{coord, years:set, lastrow, lastyear}]
    clusters: dict[str, list[dict]] = defaultdict(list)
    current_rows: list[dict] = []
    for year, cache_name, url in snapshots:
        rows = [r for r in cached_csv(cache_name, url)
                if r.get("Award") in AWARDS and r.get("Name")]
        if year == current_year:
            current_rows = rows
        print(f"{year}: {len(rows)} rows")
        for row in rows:
            try:
                coord = (float(row["Latitude"]), float(row["Longitude"]))
            except (ValueError, KeyError, TypeError):
                continue
            key = norm(row["Name"])
            if not key:
                continue
            for cluster in clusters[key]:
                if dist_m(cluster["coord"], coord) <= 500:
                    cluster["years"].add(year)
                    if year >= cluster["lastyear"]:
                        cluster.update(lastrow=row, lastyear=year, coord=coord)
                    break
            else:
                clusters[key].append(
                    {"coord": coord, "years": {year}, "lastrow": row, "lastyear": year})

    if len(current_rows) < 10_000:
        sys.exit(f"sanity check failed: only {len(current_rows)} current rows")

    with open(RESOURCES / "michelin.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUT_COLS)
        writer.writeheader()
        for row in current_rows:
            writer.writerow(reduced_row(row))

    history_cols = OUT_COLS + ["Years", "Current"]
    n_former = 0
    with open(RESOURCES / "michelin_history.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=history_cols)
        writer.writeheader()
        for cluster_list in clusters.values():
            for cluster in cluster_list:
                years = compress_years(cluster["years"])
                if current_year in cluster["years"]:
                    writer.writerow({
                        "Name": cluster["lastrow"]["Name"],
                        "Latitude": cluster["lastrow"]["Latitude"],
                        "Longitude": cluster["lastrow"]["Longitude"],
                        "Years": years, "Current": "1",
                        **{c: "" for c in OUT_COLS
                           if c not in ("Name", "Latitude", "Longitude")},
                    })
                else:
                    n_former += 1
                    out = reduced_row(cluster["lastrow"])
                    out.update(Years=years, Current="0")
                    writer.writerow(out)

    print(f"wrote michelin.csv ({len(current_rows)} rows) and "
          f"michelin_history.csv ({n_former} former places)")


if __name__ == "__main__":
    main()
