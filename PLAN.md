> **Historical document.** This is the original pre-build spec, kept for
> the reasoning behind decisions; the app has since been renamed FeedYu
> and grew beyond it (all Michelin tiers, listing history, localization).
> Current truth: docs/ARCHITECTURE.md and docs/DEVELOPMENT.md.

# DinePick — iPhone Restaurant Suggestion App

Implementation plan. This document is self-contained: a fresh Claude Code session on a Mac
should be able to build the app from this spec without re-deriving any decisions.

## What the app does

The user saves restaurants in Google Maps (starred places + "Want to go" list, the latter
mostly from the Michelin Guide). Today they manually ask an LLM for dinner suggestions and
have to separately verify open hours and traffic. This app replaces that:

1. **Tonight tab (main screen):** open the app → it immediately shows one restaurant
   suggestion from the user's saved places, reachable within a configurable drive-time
   budget (30 or 60 min, default 60) in **current traffic**. A **Refresh** button cycles to
   a different suggestion when the current one doesn't match their mood (no repeats until
   the candidate pool is exhausted).
2. **Michelin tab:** all Michelin **Starred (1–3 stars) AND Bib Gourmand** restaurants
   within the drive-time budget. User picks a price band (**$ to $$$$**), presses a button,
   gets a random suggestion from that band. Refresh works the same way.
3. Tapping any suggestion **opens it in Google Maps** so the user manually confirms open
   hours and live traffic there (deliberate decision — see "No Google API key" below).

## Decisions already made with the user (do not re-ask)

- **Platform:** Native iOS, SwiftUI. User has a Mac + Xcode.
- **Primary data source:** scraping the user's *shared* Google Maps lists (zero manual
  steps day-to-day). User explicitly accepts scraper fragility **because**:
- **Abstraction layer is mandatory:** a `RestaurantDataSource` protocol so that when
  Google changes their page, only the sync/data-update layer breaks — the app keeps
  working from its local store, and we patch just the scraper. Multiple sources feed the
  same local store to increase reliability:
  1. `GoogleSharedListSource` — scrape shared-list links (primary, automatic)
  2. `TakeoutImportSource` — Google Takeout file import (reliable manual fallback)
  3. `MichelinDataSource` — open dataset, bundled snapshot + auto-refresh from GitHub
- **App owns the list:** sources sync *into* a local store; user can also add/hide/remove
  restaurants in-app. Sync failures degrade gracefully (show last-sync status, never block).
- **No Google Maps Platform API key.** User declined Cloud billing setup. Consequences:
  - Drive time with traffic: use **Apple MapKit `MKDirections.calculateETA`** — free,
    on-device API key not needed, traffic-aware. Good enough for the ≤N-minutes filter.
  - Open hours: **not checked by the app.** The suggestion card opens the place in Google
    Maps where the user confirms hours/traffic manually. (Explicit user decision.)

## Architecture

```
DinePick/
├── DinePickApp.swift            # @main, TabView: Tonight | Michelin | Settings
├── Models/
│   └── Restaurant.swift         # Codable. id, name, coords, address, googleMapsURL,
│                                # lists: Set<ListKind> (starred/wantToGo), michelin:
│                                # award (.oneStar/.twoStars/.threeStars/.bibGourmand)?,
│                                # priceBand (1-4)?, cuisine?, isHidden, addedManually,
│                                # lastSeenInSourceAt
├── DataSources/
│   ├── RestaurantDataSource.swift  # protocol: id, displayName,
│   │                               # func fetch() async throws -> [Restaurant]
│   ├── GoogleSharedListSource.swift
│   ├── TakeoutImportSource.swift
│   └── MichelinDataSource.swift
├── Store/
│   └── RestaurantStore.swift    # ObservableObject; JSON persistence in Application
│                                # Support; merge/dedupe logic; per-source sync status
├── Engine/
│   └── SuggestionEngine.swift   # candidate filtering + ETA check + shuffled no-repeat queue
├── Views/
│   ├── TonightView.swift        # suggestion card + big Refresh button
│   ├── MichelinView.swift       # price band picker ($–$$$$), star/bib filter toggles, Suggest button
│   ├── SettingsView.swift       # drive budget, list URLs, sync status, Takeout import
│   └── RestaurantCard.swift     # shared card: name, distance/ETA, award badge, cuisine,
│                                # "Open in Google Maps" action
└── Resources/
    └── michelin.csv             # bundled snapshot (see below)
```

Persistence: plain Codable JSON file (simplest to hand-write correctly; SwiftData optional
later). Dedupe key when merging sources: normalized name + coordinates within ~100 m
(sources don't share stable IDs). Never delete a restaurant just because one source stopped
returning it — mark `lastSeenInSourceAt`, let the user prune.

### Suggestion engine (both tabs)

1. Pre-filter candidates by straight-line distance from current location:
   radius ≈ budgetMinutes × 1.3 km/min (generous; avoids ETA calls for hopeless candidates).
2. Shuffle the pre-filtered pool once per "session" (until refreshed pool is exhausted or
   location moves significantly).
3. Pop the next candidate, compute `MKDirections.calculateETA` (automobile, departure =
   now → traffic-aware). If ETA ≤ budget → show it. Else skip to next.
4. **Rate-limit caution:** MapKit throttles directions requests. Only compute ETA for the
   candidate being considered (lazily, one at a time), cache ETAs for ~10 min per place.
5. Refresh button = pop next passing candidate. Track shown IDs; don't repeat until pool
   exhausted, then reshuffle.

### Opening in Google Maps

Prefer the stored per-place Google URL (Takeout/scrape/Michelin `Url` field opens the exact
place page). Fallback: `comgooglemaps://?q=<name>&center=<lat>,<lng>` if the app is
installed (declare `comgooglemaps` in `LSApplicationQueriesSchemes`), else
`https://www.google.com/maps/search/?api=1&query=<name>%20<address>`.

## Data sources — implementation details

### 1. GoogleSharedListSource (primary, zero manual steps)

- User shares each list (starred is not shareable; "Want to go" and custom lists are) →
  gets a `https://maps.app.goo.gl/…` link → pastes it once into Settings (can add multiple,
  each tagged with which ListKind it represents).
- Fetch: URLSession GET, follow redirects to the full `google.com/maps/...` page. The page
  embeds list data in a JS blob (`window.APP_INITIALIZATION_STATE = [[[...`). Parse
  tolerantly (regex/scanning, not strict JSON): extract place name strings adjacent to
  coordinate pairs (`[null,null,<lat>,<lng>]` patterns) and hex ftids
  (`0x…:0x…`) for building place URLs.
- **This is the fragile component.** Requirements: never crash on parse failure; report
  per-source sync status (last success time + error) in Settings; unit-test the parser
  against a saved HTML fixture so breakage is caught by tests. Build & verify against a
  real shared-list link early (create a test list with a few places).
- Note: starred places can't be shared, so starred sync relies on Takeout import; the
  "Want to go" list (the one the user cares most about) works via scraping.

### 2. TakeoutImportSource (manual fallback, also the only route for Starred)

Google Takeout → select "Maps (your places)" and "Saved":
- **Starred:** `Saved Places.json` — GeoJSON, has coordinates directly. Easy.
- **Want to go / custom lists:** `Saved/<ListName>.csv` — columns Title, Note, URL.
  **No coordinates.** Resolve best-effort, in order: (a) fetch the place URL and regex
  `@<lat>,<lng>` or `!3d<lat>!4d<lng>` from the redirect/HTML; (b) `CLGeocoder` on the
  title; (c) import without coords (excluded from distance filtering, still listed).
- Import UI: `.fileImporter` accepting .json/.csv/.zip in Settings.

### 3. MichelinDataSource

- Open dataset: https://github.com/ngshiheng/michelin-my-maps — regularly re-scraped from
  guide.michelin.com.
- Raw CSV: `https://raw.githubusercontent.com/ngshiheng/michelin-my-maps/main/data/michelin_my_maps.csv`
- **Verified 2026-07-05:** 19,405 rows. Columns:
  `Name,Address,Location,Price,Cuisine,Longitude,Latitude,PhoneNumber,Url,WebsiteUrl,Award,GreenStar,FacilitiesAndServices,Description`
  Award distribution: Selected Restaurants 11,820 / Bib Gourmand 3,705 / 1 Star 3,175 /
  2 Stars 544 / 3 Stars 161. Keep only stars + Bib Gourmand → **7,585 rows**.
  Price is mostly already `$`…`$$$$` but ~400 rows use local symbols (€€€, ¥¥¥¥, ££).
  **Normalize price band = symbol count, clamp 1–4.**
- Bundle a preprocessed snapshot (`Resources/michelin.csv`: keep columns
  Name,Address,Location,Price,Cuisine,Longitude,Latitude,Url,Award,Description; truncate
  Description to ~200 chars; stars+bib only) and auto-refresh from the raw GitHub URL
  (e.g. weekly / on app launch if stale), falling back to the bundle.

Preprocessing script used to generate the bundle (run with the downloaded full CSV):

```python
import csv
rows = list(csv.DictReader(open('michelin_my_maps.csv')))
keep = [r for r in rows if r['Award'] in ('1 Star','2 Stars','3 Stars','Bib Gourmand')]
cols = ['Name','Address','Location','Price','Cuisine','Longitude','Latitude','Url','Award','Description']
w = csv.DictWriter(open('Resources/michelin.csv','w',newline=''), fieldnames=cols)
w.writeheader()
for r in keep:
    out = {c: r[c] for c in cols}
    out['Price'] = '$' * min(4, max(1, len(out['Price']))) if out['Price'] else ''
    out['Description'] = out['Description'][:200]
    w.writerow(out)
```

## Screens

- **Tonight:** one large `RestaurantCard` (name, cuisine if known, ETA in current traffic,
  which list it came from, Michelin badge if cross-matched) + prominent Refresh button +
  "Open in Google Maps". Empty states: no location permission / no restaurants in range /
  no data yet (prompt to add a list URL or import Takeout).
- **Michelin:** segmented price picker $ / $$ / $$$ / $$$$ (allow multi-select or "any"),
  toggles for ⭐/⭐⭐/⭐⭐⭐/Bib (default all on), Suggest button → card as above, plus a
  browsable list of everything in range below.
- **Settings:** drive-time budget picker (30 / 60 min + custom stepper 15–90); shared-list
  URLs (add/remove, tag as Want-to-go/custom); per-source last-sync status + Sync Now;
  Takeout file import; Michelin data refresh + dataset date; hidden-restaurants management.

## iOS specifics

- Location: `CLLocationManager`, when-in-use authorization;
  `NSLocationWhenInUseUsageDescription` in Info.plist.
- `LSApplicationQueriesSchemes: [comgooglemaps]` in Info.plist.
- Min iOS 17 target is fine (user's own device only).
- Distribution: user's personal device via Xcode — free Apple ID (7-day resign) or
  $99/yr developer account. No App Store plans.

## Suggested build order (verify each step on the Mac)

1. Xcode project skeleton, models, JSON store, tabs with placeholder views.
2. MichelinDataSource from the bundled CSV + Michelin tab with price filter and random
   suggest (no ETA yet — straight-line distance first). **This tab has zero scraping risk
   and delivers value immediately.**
3. Location + MapKit ETA integration in SuggestionEngine; wire budget setting.
4. TakeoutImportSource (starred GeoJSON first, then Want-to-go CSV with coord resolution).
5. Tonight tab on top of the store + engine.
6. GoogleSharedListSource scraper last (fragile; test against a real shared link, save an
   HTML fixture for unit tests).
7. Polish: sync status UI, hidden/manual restaurants, ETA caching, empty states.

## Risks / known limitations

- Shared-list scraping breaks whenever Google changes the page format — by design this
  only breaks sync, never the app; fix = update one parser.
- Starred places cannot be shared → starred list only updates via Takeout import.
- No open-hours checking (no API key) — user confirms in Google Maps by design. If this
  becomes annoying, the future upgrade path is a Google Places API key (hours) and/or
  scraping hours from the place URL.
- MapKit ETA throttling — keep ETA requests lazy and cached.
- Michelin dataset is worldwide (7.5k rows) — always filter by distance before showing.
