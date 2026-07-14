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
│                          → Michelin sync if stale → weekly list sync
│                          (enabled shared lists re-sync when lastSuccess
│                          > 7 days; foreground returns re-check lists,
│                          re-sync Michelin when its weekly clock is
│                          stale, and refresh location when the fix is
│                          older than 30 min — launch and foreground use
│                          the SAME staleness gates, so neither path
│                          re-parses/re-fetches fresh data; FAILING
│                          refreshes back off and retry hourly at most,
│                          gated on each source's lastAttempt — an offline
│                          stretch must not re-download/re-parse per
│                          foreground return)
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
- `uberEatsURL` / `uberEatsNotFoundAt` / `uberEatsClosedUntil` /
  `mapsNoMatchAt`+`mapsNoMatchName` — verification results and
  cooldown/suppression markers filled by the Uber checker and the cid
  resolver (semantics in the Engine section and MAINTENANCE playbooks);
  each cleared by its own later success.
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
  (`Snapshot { restaurants, syncStatuses }`, ISO-8601 dates), saved on a
  detached task with a 3 s debounce + 20 s deadline — mutation bursts (a
  localizer fill run lands ~40 names seconds apart) coalesce into a few
  multi-MB rewrites instead of one per mutation, while the deadline bounds
  force-quit loss. Writes are serialized (each save awaits its
  predecessor): the deadline path schedules at zero delay, and two
  overlapping atomic writes could land the OLDER snapshot last. ~25k
  restaurants ≈ 15 MB; loads off-main. A store file that exists but fails
  to decode is set aside as `store.json.corrupt` (newest copy kept) before
  the app continues empty — the next save must not overwrite the user's
  only copy.
- `version` (bumped in the `restaurants` didSet) keys the views' memoized
  derived collections; `indexByID` (rebuilt there too) backs O(1)
  `restaurant(withID:)` lookups — per-mutation O(n) rebuild traded for
  eliminating per-render O(n) scans (see Gotcha #12).
- `sync(_ source:)` wraps `fetch()` with status bookkeeping. Errors land in
  `SyncStatus.lastError`; the previous data stays.
- **Dedupe/merge rules** (in `apply`, in priority order):
  1. identical `googleMapsURL`
  2. same normalized name AND coordinates within **150 m**
  3. same normalized name, incoming has no coordinates, and the name is
     unique among USER rows — rows with any non-"michelin" source stamp or
     addedManually (Takeout CSV case). Guide-ONLY rows never name-match a
     coordinate-less incoming: with ~19k of them loaded, a same-named
     guide place anywhere on earth would swallow the user's place (it
     inherits the foreign coordinates and falls out of every radius). The
     discriminator is deliberately the stamps, not michelinAward — a user
     place that merged with its local guide row carries the award and must
     keep matching its own re-imports. Guide rows still merge via rule 2.
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
  Modes remember their own values, per page — Tonight and Michelin have
  independent `AppSettings.PageBudget`s and the Uber tab its own radius
  (`uberDistanceMeters`); quick
  selector on Tonight, fine steppers in Settings.
- A "session" = (origin ± min(2 km, radius/2), budget, candidate-id set).
  Any change rebuilds the shuffled queue and clears the shown-set.
- Straight-line prefilter radius: exact `value` m for distance mode;
  `min × 85 m` walking; `min × 1.3 km` driving — generous, only exists to
  avoid pointless ETA calls. Best-case bound: never surface an in-radius
  COUNT in UI as if it meant "suggestible" (see TravelBudget.radiusMeters);
  Michelin's walk/drive list header says "straight line" for the same
  reason. Computed ONCE per session via a `SpatialGrid`
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
  a ~500 m grid. Max 12 ETA checks per refresh on walk/drive; the Uber tab
  caps at 25 slow WebView availability checks per refresh (an unbounded
  first scan of a dense area ran for minutes on one press). A paused scan
  requeues where it stopped and says "Checked many stores — refresh to
  keep looking" (deliberately count-less: quickReject skips don't count,
  so a number would undercount the pass) — the next press resumes
  mid-queue, and `quickReject` + persisted notFound cooldowns keep
  re-walks free, so the tab still never falsely claims "no results".
  A cancelled refresh (leaving the tab cancels the search task; the
  auto-suggest .task cancels with the view) stops at the next candidate,
  keeping queue position. A drained queue wraps the rotation once in-place
  instead of ending with "press again".
- `quickReject` (optional injectable): free synchronous skip, NOT counted
  against the check budget (Uber tab: places in notFound cooldown).
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
  per-refresh budget (25 on this tab); verdicts session-cached by
  restaurant id — NOT by name: same-named chain branches must not share a
  verdict, or one branch's verified store URL gets persisted onto the
  other. A known store's OPEN state is deliberately NOT cached (product
  decision — don't "optimize" it back): the card is the moment before the
  user taps "order", so open-now is re-verified LIVE per shown suggestion
  (one getStoreV1 JSON call); a 10-minute-old "open" can be a closed store
  by now. Only `closedNow` short-circuits — it self-expires at Uber's own
  reopen time, so it can't go stale in the wrong direction — and the
  reopen stamp PERSISTS (`uberEatsClosedUntil`, 10-min fallback when Uber
  gave no time): relaunches skip known-closed stores for free via
  quickReject until the stamp passes, then the live check decides again
  (suppress-only — an afternoon of closed restaurants used to cost one
  live check each, on every launch). Closed-now itself is judged by TWO
  signals (see the MAINTENANCE playbook): the `storeAvailablityStatus`
  state deny-list — which catches merchant pauses whose `nextOpenTime` is
  null — and the future-`nextOpenTime` schedule rule. The check
  retries once on transport failure (the Uber tab auto-rolls at launch,
  making this the app's FIRST WebView call — cold calls throw; single-shot
  it failed open and the initial card could be a closed store), then fails
  open with a debugLog. The transport is injectable
  (`UberEatsChecker.runJS`) so these contracts are unit-tested — see
  docs/REQUIREMENTS.md "Uber Eats". A verified
  notFound persists with a week's cooldown (skipped free via quickReject);
  `unknown` (bot wall) is never persisted. (v1 name-only URLs were wiped
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
  URL (or on Settings → Refresh now). The download is a conditional GET:
  the cache file's ETag is saved with it, and an unchanged upstream answers
  HTTP 304 — the weekly clock advances without the multi-MB body.
- The auto-refresh is Wi-Fi/unmetered only (`allowsExpensiveNetworkAccess
  = false`, same etiquette as GooglePlaceResolver — a multi-MB body nobody
  asked for right now); Settings → Refresh now keeps full network access.
- Refresh failures: every attempt stamps `lastRemoteAttempt`, and the app's
  staleness gate retries at most hourly (`remoteRetryBackoff`) — a stale
  dataset + no network must not re-attempt per foreground return. When the
  store already holds guide rows the gate also passes
  `fallsBackToLocal: false`: the failure throws into SyncStatus instead of
  re-parsing/re-merging ~19k unchanged local rows. The local fallback stays
  on only for seeding an empty store (first launch, store restore).
  Settings → Refresh now bypasses the backoff entirely (forceRemote).
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
| UserDefaults | `tonightBudget` / `michelinBudget` | JSON `PageBudget` per page: mode + each mode's own remembered value |
| UserDefaults | `uberDistanceMeters` | the Uber tab's delivery radius (100–50000) |
| UserDefaults | `travelMode`, `driveBudgetMinutes`, `distanceBudgetMeters`, `walkBudgetMinutes` | LEGACY single-budget keys — read once at init to seed the per-page budgets on upgrade, never written |
| UserDefaults | `hasSeenOnboarding` | first-launch walkthrough dismissed |
| UserDefaults | `uberEatsURLsResetV2` | one-time v1 store-URL wipe flag |
| UserDefaults | `sharedListConfigs` | JSON `[SharedListConfig]` (incl. isEnabled) |
| UserDefaults | `importedListConfigs` | JSON `[ImportedListConfig]` (Takeout lists) |
| App Group `group.com.yuyu.FeedYu` | `pendingSharedListURLs` | share-extension inbox |
| UserDefaults | `languageChoice` + `AppleLanguages` | UI language override |
| UserDefaults | `michelinNameLanguage` | local/en/zh/ja, default local |
| UserDefaults | `michelinLastRemoteRefresh` | weekly refresh clock (advances on success/304) |
| UserDefaults | `michelinLastRemoteAttempt` | failure-backoff clock (hourly retries) |
| UserDefaults | `michelinCacheETag` | ETag of michelin-cache.csv (conditional GET) |
| UserDefaults | `michelinPriceBands` / `michelinAwardFilters` | Michelin tab filter chips (persisted) |
| App Support/FeedYu | `store.json` | the entire restaurant store |
| App Support/FeedYu | `michelin-cache.csv` | last downloaded dataset |
| launch args (automation) | `initialTab`, `uiTestSeed`, `uiTestResetFilters` | tab override for screenshots; DEBUG UI-test seed hooks (UITestSeed.swift) |

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
10. **Case-based heuristics silently eat caseless scripts.** The name
    filter's "reject short ALL-CAPS codes" rule ("JP", "USD") also matched
    every 2–3-character CJK restaurant name (松滿樓 == its own uppercased
    form) — 17 places of one real list vanished. Any `== .uppercased()`
    check needs a `!= .lowercased()` companion to prove the string has
    case at all. Similarly, coordinate-rounding dedupe (~11 m) collapsed
    *different restaurants in the same building* — dedupe scraped places
    by name, not by pin.
11. **Don't gate cid resolution behind the summary/image fetch guard.**
    Michelin places ship with a CSV summary and get their photo on the
    first card display, so `PlaceInfoFetcher`'s "both fields set → return
    early" guard gave `GooglePlaceResolver` one shot ever per place — a
    single failed attempt left it on (search-results-prone) search-URL
    opens permanently. Resolution now has its own per-session gate
    (`resolvedMapsURL`), and taps race it against a short timeout.
12. **Computed view properties that scan the whole store must be
    memoized.** A SwiftUI computed property is re-evaluated on EVERY
    access, and a body reads helpers like `michelinInRange` several times
    (task ids, section headers, footers) — with a ~20k-row store that was
    100k+ distance computations per render, on the main thread, on every
    `@Published` change. Pattern: cache in a reference-type box in
    `@State`, keyed on `store.version` + the other inputs
    (MichelinView.InRangeCache, TonightView.CandidatesCache,
    SettingsView.StoreTalliesCache, ManageRestaurantsView.PlacesCache —
    the last one was missed until a 2026-07 review; any NEW view that
    scans the store gets a box too).
13. **`try? await Task.sleep` swallows cancellation inside loops.** The
    localizer's fill loop kept iterating after its `.task(id:)` was
    cancelled: each URLSession call failed instantly with
    `CancellationError`, and recording those as failures poisoned the
    session-long negative cache (names silently never localized). Loops
    that persist failure verdicts must check `Task.isCancelled` before
    both continuing and recording.
14. **A bare `.accessibilityLabel` on a container swallows its children.**
    The price-filter HStack's label collapsed it into ONE accessibility
    element — VoiceOver lost the four chip buttons entirely, and the UI
    contract tests couldn't find them on the visible page (offscreen pager
    pages expose the raw tree, masking the bug in `exists` checks). Label
    a container via `.accessibilityElement(children: .contain)` +
    `.accessibilityLabel(...)`.
15. **A reused card's @State outlives its restaurant.** RestaurantCard is
    swapped in place when a suggestion is replaced (budget revalidation),
    so SwiftUI keeps the view's identity — and the OLD restaurant's
    cancelled-but-still-running photo fetch wrote its result onto the NEW
    restaurant's card (a curry place wearing a mochi shop's photo; button
    rolls masked it because the LoadingCard swap destroys the state).
    Cards get per-restaurant identity (`.id(suggestion.id)`) AND the
    fetch task checks `Task.isCancelled` before writing — a cancelled
    Swift task keeps executing past its awaits unless it checks.
16. **Uber's getStoreV1 hides closure from location-less requests.** The
    open check's two closed signals (state deny-list, `nextOpenTime`)
    only appear when the call carries the `uev2.loc` cookie; without it
    a closed store reports `TOO_FAR_TO_DELIVER` + `nextOpenTime: null`
    and fails open. The cookie is session-scoped and was only set by the
    search pipeline, so every cold launch's known-store checks ran blind
    until some search happened to run first — a 22:00-opening steakhouse
    reached the lunch card that way (2026-07-14). `fetchStoreBody` now
    sets the cookie on every call; keep it.
