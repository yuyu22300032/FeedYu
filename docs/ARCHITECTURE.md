# FeedYu Architecture

How the app is put together and *why*. Read this before changing anything
structural. Page-by-page behavior, the suggestion pipeline, caching, and
integration details are in [FEATURES.md](FEATURES.md). The original product
spec is [../PLAN.md](../PLAN.md) (historical, uses the old name DinePick);
this document reflects the code as built.

## Big picture

```
┌─────────────────────  Data sources (fragile, replaceable)  ─────────────────┐
│ GoogleSharedListSource   TakeoutImportSource   MichelinDataSource           │
│ (scrapes shared lists)   (file import)         (bundled CSV + GitHub)       │
└──────────────┬───────────────────┬───────────────────┬──────────────────────┘
               └───────── fetch() → [Restaurant] ──────┘
                                   ▼
                      RestaurantStore (single source of truth)
                      merge/dedupe · JSON persistence · sync status
                                   ▼
               SuggestionEngine (per tab: shuffled no-repeat queue,
               straight-line prefilter, lazy traffic-aware MapKit ETA)
                                   ▼
        Views: TonightView · MichelinView · SettingsView · RestaurantCard
        · TravelBudgetPanel (shared constraint box)
        (+ MichelinNameLocalizer fills local-language names lazily,
           PlaceInfoFetcher fills cover photo + description lazily)
```

**Core design rule (from PLAN.md, non-negotiable):** sources sync *into* the
local store. When Google or Michelin change their pages, only the affected
source's sync breaks — the app keeps working from the store, and the fix is
one parser. Sources must never crash on garbage input; they throw
`SourceError` and the failure surfaces as per-source status in Settings.

## Directory map

```
FeedYu/
├── FeedYuApp.swift        @main; page-style TabView + custom bottom bar
│                          (swipe between tabs — see Gotchas); bootstrap() =
│                          load store → drain share inbox → request location
│                          → sync Michelin → weekly list sync (enabled
│                          shared lists re-sync when lastSuccess > 7 days;
│                          also re-checked whenever the app foregrounds)
├── Models/Restaurant.swift        Restaurant + ListKind + MichelinAward
├── Models/TravelBudget.swift      TravelMode + TravelBudget (radius/presets)
├── DataSources/
│   ├── RestaurantDataSource.swift protocol + SyncStatus + SourceError
│   ├── GoogleSharedListSource.swift   ← THE fragile one, see below
│   ├── TakeoutImportSource.swift
│   └── MichelinDataSource.swift
├── Store/RestaurantStore.swift
├── Engine/SuggestionEngine.swift
├── Engine/SpatialGrid.swift       layered lat/lng-cell index for radius queries
├── Support/
│   ├── AppSettings.swift          UserDefaults-backed settings + list registry
│   ├── CSVParser.swift            RFC 4180, CRLF-safe (see Gotchas)
│   ├── GoogleMapsOpener.swift     stored ?cid= URL → coordinate-anchored
│   │                              name search (never an unanchored q= —
│   │                              "place not found" for half the places)
│   ├── LocationProvider.swift     CLLocationManager wrapper
│   ├── MichelinNameLocalizer.swift
│   ├── PlaceInfoFetcher.swift     lazy cover-photo/description scrape (og: meta)
│   ├── ShareInbox.swift           app-group hand-off from the share extension
│   ├── UberEatsChecker.swift      "orderable?" verification (see Engine)
│   └── WebPageFetcher.swift       hidden WKWebView: bot-cleared same-origin JS
├── Views/ (TonightView, MichelinView, SettingsView, ManageRestaurantsView,
│           RestaurantCard, TravelBudgetPanel)
│           No navigation titles — pages start at the content; the tab names
│           live only in the custom bottom bar. TravelBudgetPanel scrolls
│           WITH the content on both tabs (not pinned) and is `boxed: false`
│           inside the Michelin List (see Gotchas #8).
│           Color scheme app-wide = grouped style: GRAY page, WHITE boxes.
│           Lists/Forms do it natively; Tonight/Uber set
│           systemGroupedBackground on the page themselves, and the card +
│           boxed panel use secondarySystemGroupedBackground (solid — the
│           old thinMaterial card vanished on gray). Michelin's panel and
│           filters share ONE section (one box); its suggestion-card row is
│           listRowBackground(.clear) because the card brings its own box.
└── Resources/
    ├── michelin.csv               current guide, all awards (~19.4k rows)
    ├── michelin_history.csv       years-on-list overlay + former places
    ├── Localizable.xcstrings      en source + zh-Hant + ja (~130 keys)
    └── InfoPlist.xcstrings        location-permission string

FeedYuShare/                       share-sheet extension target: accepts a
                                   Google Maps share (URL or text), drops the
                                   link in ShareInbox; the app drains it on
                                   next activation into a SharedListConfig.
                                   Own 2-key Localizable.xcstrings.
```

**User lists** (up to `AppSettings.maxLists` = 20): every list — shared
Google Maps links (`SharedListConfig`) and Takeout imports
(`ImportedListConfig`, registered at import; legacy imports self-register at
bootstrap) — has an `isEnabled` toggle in Settings. Tonight candidates =
places whose `lastSeenInSourceAt` contains an *enabled* list's sourceID (or
`addedManually`); membership is the source stamps, not `lists: Set<ListKind>`
(which only feeds badges/kind icons now). Both config types decode with
`decodeIfPresent` defaults — a synthesized decoder would drop every persisted
list when a new field is added (same trap as the Restaurant rule).
Lists are renameable (pencil) and removable (trash + confirmation):
`RestaurantStore.removeList` strips the list's stamp everywhere and deletes
only places left with no other registered list that are neither manually
added nor on the Michelin guide.

## Model: `Restaurant`

One struct for every kind of place (user-saved, Michelin, former-Michelin,
manual). Key fields and their contracts:

- `id: UUID` — store identity only; never derived from source data.
- `latitude/longitude: Double?` — optional; `(0,0)` is treated as missing
  (`coordinate` returns nil). Places without coordinates are excluded from
  distance filtering but still listed/manageable.
- `lists: Set<ListKind>` — which user lists it belongs to. **Empty set means
  "not a user place"** (e.g. Michelin-only rows); TonightView filters on this.
- `michelinAward/`…`Years/`…`Former` — guide data. `michelinFormer == true`
  means it dropped off the current guide (from the history overlay).
- `localizedNames: [String: String]?` — guide-edition key (`"zh_TW"`, `"ja"`)
  → fetched display name. Filled lazily by `MichelinNameLocalizer`.
- `lastSeenInSourceAt: [sourceID: Date]` — sync bookkeeping; sources never
  delete, they just stop stamping (user prunes manually).
- `isHidden` — user flag; **must survive re-syncs** (merge never touches it).
- `summary`/`imageURL` — description + cover photo, filled lazily by
  `PlaceInfoFetcher` when a card is shown (Michelin guide page's og: meta
  when there's a michelinURL — mobile Safari UA — else the Google Maps place
  page — desktop UA). Store writes are fill-only; scraping never overwrites.
  Google serves stock artwork (static map / geocode card) as og:image for
  photo-less places — `isGenericImage` rejects those at fetch AND display
  time. Card shows placeholders instead: `NoPictureCover` asset for user
  places, a fork glyph for Michelin. The cover image doubles as the
  open-in-Google-Maps button (there is no separate button).

**Codable back-compat rule:** the persisted store (`store.json`) is decoded
with synthesized Codable. Any NEW stored property MUST be `Optional` (or the
decode of every existing store fails silently and the user's data appears
wiped). This bit us once; don't repeat it. `michelinYears: String?`,
`michelinFormer: Bool?`, `localizedNames: [...]?` follow this rule.

`merge(with:)` is additive-only: union lists, fill nils, prefer incoming
Michelin fields, never clear anything, never touch `isHidden`.

## Store: `RestaurantStore` (@MainActor)

- Persistence: single JSON file `Application Support/FeedYu/store.json`
  (`Snapshot { restaurants, syncStatuses }`, ISO-8601 dates), saved with a
  0.8 s debounce on a detached task. ~25k restaurants ≈ 15 MB; loads off-main.
- `sync(_ source:)` wraps `fetch()` with status bookkeeping. Errors land in
  `SyncStatus.lastError`; the previous data stays.
- **Dedupe/merge rules** (in `apply`, in priority order):
  1. identical `googleMapsURL`
  2. same normalized name AND coordinates within **150 m**
  3. same normalized name, incoming has no coordinates, and the name is
     unique in the store (Takeout CSV case)
  Otherwise append. Name normalization = casefold + strip diacritics + keep
  alphanumerics only (CJK survives). Matching uses hash indexes so a 25k-row
  sync stays O(n).
- Known limitation: a place saved under a local-script name (鮨さいとう) does
  NOT merge with its romanized Michelin row (Sushi Saito) — names differ and
  coordinate-only matching is deliberately not done (same-building restaurants
  share coordinates). Both entries may appear; the user can hide one.
  Candidate future fix: cross-script matching via coordinates ≤40 m + same
  price/cuisine, or via Google cid lookup.

## Engine: `SuggestionEngine` (@MainActor, one instance per tab)

- Budget = `TravelBudget` (mode + value): `.distance` (meters, straight-line,
  ZERO route lookups), `.walking` / `.driving` (minutes, route-verified).
  Modes remember their own values (`AppSettings.travelBudget`); quick
  selector on Tonight, fine steppers in Settings.
- A "session" = (origin ± min(2 km, radius/2), budget, candidate-id set).
  Any change rebuilds the shuffled queue and clears the shown-set.
- Straight-line prefilter radius: exact `value` m for distance mode;
  `min × 85 m` walking; `min × 1.3 km` driving — generous, only exists to
  avoid pointless ETA calls. Computed ONCE per session via a `SpatialGrid`
  query (layered lat/lng cells, ~5.5/22/88 km), not per refresh.
- Queue order: shuffled within thirds-of-radius distance rings, nearest ring
  first — try the user's own "city" before neighboring ones so early ETA
  checks mostly pass.
- Pops candidates one at a time; distance mode accepts immediately
  (`etaMinutes = nil`), walk/drive check `MKDirections.calculateETA`
  (`.walking`/`.automobile`, `departureDate = now` → traffic-aware, free, no
  API key). Passes if ETA ≤ budget. **Never batch ETA calls** — MapKit
  throttles; `MKError.loadingThrottled` is caught, the candidate is requeued,
  and the user is told to wait a minute.
- ETA cache: 10 min TTL, keyed by restaurant id + mode + origin bucketed to
  a ~500 m grid. Max 12 ETA checks per refresh.
- `availabilityCheck` (optional injectable): post-budget filter used by the
  Uber Eats tab (`TonightView(uberEatsMode: true)` — same candidates and
  engine as Tonight, but ALWAYS on the distance budget:
  `TravelBudgetPanel(distanceOnly: true)` drives `distanceBudgetMeters`
  without touching the other tabs' mode). `UberEatsChecker` verifies via
  Uber's own JSON APIs called same-origin from a bot-cleared WKWebView
  (`WebPageFetcher.callJS` — device logs proved ubereats.com serves a JS
  bot-defense shell to bare URLSession and gates /search HTML behind a
  location redirect; only real WebKit gets through):
  (1) `getSearchSuggestionsV1` (user location via `document.cookie
  uev2.loc`) → storeUuid/title candidates, parsed from each store's
  enclosing JSON object via balanced-brace scan — field order isn't
  guaranteed and a char-distance heuristic let stores inherit a neighbor's
  coordinates; (2) fuzzy name rank (containment + normalized Levenshtein);
  (3) geo within **100 m** of our saved coordinates (feed geo, else a
  `getStoreV1` lookup, ≤2 per check) plus a ≥0.5 name score — geo is the
  strong signal; with no geo anywhere only ≥0.85 passes. Verified → the
  canonical `store-browse-uuid/<uuid>?diningMode=DELIVERY` URL persisted to
  `Restaurant.uberEatsURL`; the card's order button re-reads the store row
  at tap time (the Suggestion snapshot predates verification — this bug
  shipped once). Real results but nothing verified → drop candidate;
  API/JS failure (one retry) → PERMISSIVE unknown (kept; button falls back
  to a search universal link — iOS hands ubereats.com URLs to the
  installed app without any web request). Checks count against the
  per-refresh budget (6 on this tab); results session-cached by normalized
  name, notFound deliberately not persisted. (v1 name-only URLs were wiped
  once via the `uberEatsURLsResetV2` flag.)
- No repeats until the in-range pool is exhausted, then reshuffle (avoiding
  an immediate repeat of the current card).
- `etaProvider` is an injectable closure — tests (and any future routing
  backend) swap it without touching MapKit.

## Data sources

### GoogleSharedListSource — the fragile one

Wire format as of 2026-07-05 (verified against a real list; synthetic
fixtures in `FeedYuTests/Fixtures/` mirror it byte-for-byte):

1. `maps.app.goo.gl/…` links serve a **JS interstitial** to browser UAs.
   Appending `?_imcp=1` makes them redirect straight to the real page.
2. The list page no longer inlines places. It embeds a tokenized XHR path
   (`entitylist/getlist?authuser=0&hl=…&pb=…`, HTML-escaped) —
   `extractGetlistPath` pulls it out; fetch it under
   `https://www.google.com/maps/preview/`.
3. The getlist response (`)]}'` prefix, JS-array body) contains per-place:
   `[null,null,<lat>,<lng>]` coordinates, then **immediately** a
   `["<tile>","<cid>"]` id pair, then the display name string.
4. `parsePlaces` is a tolerant scanner (regex, no strict JSON): coordinate
   pattern → look in a window after it for the id pair and the first
   *plausible* name string. Plausibility filters reject URLs, ftids, numbers,
   JSON fragments (`[]{}`/null-noise), etc.
5. **cid adjacency rule:** only accept an id pair within ~70 chars right
   after the coordinates. Pairs further out belong to *neighboring* places —
   a wrong cid silently opens the wrong restaurant in Google Maps. No cid is
   always better than a wrong one (fallback = name+address search URL).
6. `Accept-Language` is the device language → place names arrive in local
   script. Re-sync after changing app language.
7. The old inline `APP_INITIALIZATION_STATE` path is still tried first.

When Google changes the format: capture the new page/response (keep real
captures OUT of git — they contain account ids and personal lists; scratch
them locally), fix `parsePlaces`/`extractGetlistPath` until the fixture-based
tests pass with an updated *synthetic* fixture.

### MichelinDataSource

- Load order: cached download (`michelin-cache.csv` in App Support) → bundled
  `michelin.csv`. Auto-refreshes weekly from the michelin-my-maps GitHub raw
  URL (or on Settings → Refresh now); refresh failures fall back silently.
- All award tiers parse (`Selected Restaurants` included since v2).
- After the current list loads, `applyHistoryOverlay` merges
  `michelin_history.csv`: rows with `Current=1` attach `Years` to matching
  current places (match = normalized name + ≤500 m); rows with `Current=0`
  are appended as former places (`michelinFormer = true`).
- Price bands: symbol count of `$`/`€`/`¥`/`£` strings, clamped 1–4.
- Regenerating both CSVs: `scripts/preprocess_michelin.py` (see
  [DEVELOPMENT.md](DEVELOPMENT.md#michelin-data-pipeline)).

### TakeoutImportSource

- `Saved Places.json` (starred): GeoJSON, has coordinates and
  `google_maps_url` (`?cid=` format — same scheme the scraper produces).
- List CSVs (`Title,Note,URL`): no coordinates. Resolution order: scrape the
  place URL (`!3d<lat>!4d<lng>` pin preferred over `@lat,lng` viewport) →
  `CLGeocoder` → import without coordinates. Sequential with 0.3 s delays
  (both Google and the geocoder dislike bursts).
- Zip import is NOT supported (iOS has no public unzip API) — users unzip in
  the Files app first.

### MichelinNameLocalizer

- Fetches local-script names from guide.michelin.com locale editions — the
  same URL slug works across editions (`/en/` → `/tw/zh_TW/`, `/jp/ja/`…).
- **Must use a mobile Safari User-Agent** — michelin.com's bot filter returns
  HTTP 202 + challenge to desktop/CLI agents but serves mobile Safari.
- Name = first segment of `<title>` (splits on " – " then " - ").
- The guide only has local-script names in a restaurant's own country's
  edition (a `ja` request for a Taipei place returns the romanized name), so
  the "local language" preference is the useful one. Edition per restaurant
  comes from ISO3/country hints in the dataset address (TWN→zh_TW, JPN→ja,
  HKG/Macau→zh_HK, CHN→zh_CN).
- Throttled: ≤40 fetches per Michelin-tab visit, 0.4 s apart, results cached
  forever in the store, failures negatively cached per session.

## Localization

- `Localizable.xcstrings` (en source, zh-Hant, ja). SwiftUI string literals
  in `Text`/`Button`/`Label`/`Section` localize automatically; **any string
  built outside a View literal** (engine status messages, enum labels, error
  descriptions, `importMessage`…) must go through `String(localized:)` or it
  ships English-only.
- In-app language override: Settings picker writes the `AppleLanguages`
  UserDefaults key; requires app relaunch (the picker offers "quit now").
- Michelin *name* language is a separate setting (see localizer above).
- Adding a language = add translations for the ~114 keys in the catalog +
  InfoPlist.xcstrings; nothing else.

## Settings & persisted state inventory

| Where | Key | Meaning |
|---|---|---|
| UserDefaults | `travelMode` | distance / walking / driving (default driving) |
| UserDefaults | `driveBudgetMinutes` | 15–90, default 60 |
| UserDefaults | `distanceBudgetMeters` | 100–50000, default 2000 |
| UserDefaults | `walkBudgetMinutes` | 5–120, default 15 |
| UserDefaults | `sharedListConfigs` | JSON `[SharedListConfig]` (incl. isEnabled) |
| UserDefaults | `importedListConfigs` | JSON `[ImportedListConfig]` (Takeout lists) |
| App Group `group.com.yuyu.FeedYu` | `pendingSharedListURLs` | share-extension inbox |
| UserDefaults | `languageChoice` + `AppleLanguages` | UI language override |
| UserDefaults | `michelinNameLanguage` | local/en/zh/ja, default local |
| UserDefaults | `michelinLastRemoteRefresh` | weekly refresh clock |
| App Support/FeedYu | `store.json` | the entire restaurant store |
| App Support/FeedYu | `michelin-cache.csv` | last downloaded dataset |

## Gotchas that already caused bugs (don't rediscover these)

1. **CRLF is one `Character` in Swift.** `"\r\n"` matches neither `"\r"` nor
   `"\n"` cases when iterating Characters. CSVParser handles it explicitly;
   Python's csv module writes CRLF, so the bundled CSVs are CRLF.
2. **SwiftUI Form rows merge hit-targets.** A `Button` sharing a row (same
   VStack) with a `Picker` gets its taps swallowed by the picker. One control
   per row, and `.buttonStyle(.borderless)` on buttons inside rows.
3. **Two `.fileImporter`s on the same view node silently break** — attach
   each to its own button.
4. New `Restaurant` stored properties must be Optional (see Model above).
5. Michelin/Google bot filters: michelin.com wants a mobile Safari UA;
   maps.app.goo.gl wants `_imcp=1`; google.com/maps wants a desktop UA for
   the list page. These are all encoded in the sources — keep them.
6. `xcodebuild` on this setup needs
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless
   `xcode-select` has been pointed at Xcode.
7. **`.task(id:)` re-runs on every view (re)appearance**, not just when the
   id changes — a task keyed on the travel budget re-fired on each tab
   return and replaced the current suggestion. Watch *changes* with
   `onChange`; use `.task(id:)` only with guards that make re-runs no-ops
   (e.g. `engine.current == nil`).
8. **A view's own background can vanish inside a grouped List** — the
   panel's `secondarySystemBackground` box is invisible against
   `systemGroupedBackground` (same gray in light mode). Inside a List, let
   the row be the box (`TravelBudgetPanel(boxed: false)`).
9. **A DragGesture on a standard TabView never fires over Lists/ScrollViews**
   (they claim the drag first) — swipe-between-tabs only works via
   `.tabViewStyle(.page)` + the custom bottom bar in `RootView`. Don't
   "simplify" it back to a plain TabView with tabItems.
10. **Don't gate cid resolution behind the summary/image fetch guard.**
    Michelin places ship with a CSV summary and get their photo on the
    first card display, so `PlaceInfoFetcher`'s "both fields set → return
    early" guard gave `GooglePlaceResolver` one shot ever per place — a
    single failed attempt left it on (search-results-prone) search-URL
    opens permanently. Resolution now has its own per-session gate
    (`resolvedMapsURL`), and taps race it against a short timeout.
