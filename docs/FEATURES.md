# FeedYu — Pages & How They Work

What each page does, how a suggestion is produced, and how the app talks to
Google Maps, Apple Maps, the Michelin Guide, and Uber Eats. This is the
behavior reference; code-level internals and invariants live in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Navigation

Four pages in a swipeable pager (page-style `TabView`) with a custom bottom
bar: **Tonight · Michelin · Uber Eats · Settings**. Swipe horizontally
anywhere or tap the bar to switch. Pages have no navigation titles — content
starts at the top.

On every launch (and whenever the app returns to the foreground) the app:

1. loads the local store (all restaurant data lives on-device),
2. drains the share-extension inbox (lists shared from Google Maps),
3. requests location,
4. syncs the Michelin dataset (bundled snapshot first, so the tab works
   offline/instantly),
5. re-syncs any enabled Google list whose last successful sync is **older
   than 7 days** (manual "Sync now" in Settings is always available).

---

## Tonight page

**Purpose:** answer "where should I eat tonight?" with one place at a time,
drawn from the user's own saved Google Maps places, reachable within a travel
budget.

**Candidates** = places from lists that are *enabled* in Settings (plus
manually added places), that are not hidden and have coordinates. The whole
Michelin dataset is *not* in this pool — only the user's saved places.

**Travel budget panel** (top of the page, scrolls with content):

- Three modes — **Distance** (straight line, 200 m–50 km), **Walk**
  (5–60 min), **Drive** (15–90 min). Each mode remembers its own value;
  switching modes doesn't forget the others.
- A slider snaps across the mode's presets; the **+ / −** buttons step one
  preset slot, exactly like nudging the slider.
- Changing the budget while a card is showing immediately re-suggests under
  the new constraint.

**Suggestion flow:** the page auto-suggests when data and location are ready;
"Not feeling it — another" pops the next candidate. No place repeats until
everything in range has been shown once, then the rotation reshuffles.

**The card** shows a cover photo (tapping it opens the place in **Google
Maps** — that's the "check reviews, hours, live traffic" flow; there's no
separate button), award/price/list badges, the travel line ("18 min in
current traffic" / "12 min on foot" / "1.4 km away (straight line)"), a
description, and a "View in Michelin Guide" button when the place is on the
guide. Long-press to hide a place from future suggestions. Photo and
description are fetched lazily the first time the place is suggested (see
[Lazy loading](#lazy-loading--caching)).

## Michelin page

**Purpose:** the same suggestion experience over the full Michelin dataset
(~19k current places, all tiers, worldwide) instead of the user's lists —
plus a browsable nearby list.

- One filter box at the top: the shared travel-budget panel, a
  current-guide/include-former toggle (places that dropped off the guide
  since 2022 show their listed years), price-band buttons ($–$$$$; defaults
  $ + $$; none selected = any price), and award buttons (Selected, Bib,
  1–3 stars; defaults Selected + Bib).
- **Suggest a restaurant** rolls a random match, shown on the same card as
  Tonight; the page auto-rolls on first visit. Re-pressing the button is the
  "another one" action.
- Below, every Michelin place inside the straight-line radius, nearest
  first, with award, price, cuisine, and distance; tap opens Google Maps,
  long-press hides.
- Restaurant names display in the language picked in Settings ("local
  language" by default): local-script names are fetched lazily from the
  restaurant's own country's guide edition and cached forever.

## Uber Eats page

**Purpose:** "what should I order delivery from?" — the same suggestion
engine and the same enabled lists as Tonight, with two differences:

1. **Distance-only budget.** Delivery doesn't care about drive time; the
   panel shows just the distance slider (its value is shared with the other
   tabs' distance mode).
2. **Orderability filter.** After a candidate passes the distance budget,
   the app verifies it actually exists on Uber Eats near you (see
   [Uber Eats integration](#uber-eats)). Not on the platform → the engine
   silently rolls another. Non-restaurants saved in your lists (shops etc.)
   fall out naturally here.

The card keeps the photo→Google-Maps behavior (reviews/info) and adds a
green **Order on Uber Eats** button that deep-links into the Uber Eats app,
directly on the verified store page ready to order
(`/store-browse-uuid/<uuid>?diningMode=DELIVERY`). If verification was
inconclusive (offline, bot wall), the button falls back to an Uber Eats
search for the name — the tab degrades, it never goes empty.

## Settings page

- **Language** — English / 繁體中文 / 日本語 (restart to apply). Names scraped
  from Google lists follow the device language; re-sync after switching.
- **Your lists (n/20)** — every list (shared Google Maps links and Takeout
  imports) with: an **enable toggle** (off = excluded from Tonight/Uber
  suggestions without deleting anything — for trying out a friend's list),
  a place count, **rename** (pencil), **remove** (trash + confirmation;
  deletes the list's places *except* those on another list, added manually,
  or on the Michelin guide), and per-list sync status/"Sync now".
- **Add a Google Maps shared list** — paste a `maps.app.goo.gl` link. The
  easier path: in Google Maps share the list straight to **FeedYu** (share
  extension); the app picks it up on next open.
- **Google Takeout import** — `Saved Places.json` (the starred list, which
  Google doesn't allow sharing) and list CSVs.
- **Michelin data** — dataset size/date, name-language picker, manual
  refresh from GitHub.
- **Manage & add restaurants** — browse/search all saved places,
  hide/unhide/delete, add a place manually (geocoded from name + address).

---

## The suggestion engine

One engine instance per page, all running the same layered pipeline. The
design goal: **the expensive checks run on as few candidates as possible,
and only when a suggestion is actually requested.**

```
all restaurants in the store
  │  layer 0 — list filter (free)
  │    enabled lists only · not hidden · has coordinates
  ▼
candidate pool
  │  layer 1 — spatial prefilter (in-memory, once per session)
  │    SpatialGrid radius query around the user
  ▼
in-range pool  ──→  queue: shuffled within distance rings, nearest first
  │  layer 2 — route verification (network, per candidate, lazy)
  │    Apple Maps ETA — skipped entirely in distance mode
  ▼
  │  layer 3 — availability (network, per candidate, Uber tab only)
  │    Uber Eats store match within 100 m
  ▼
the suggestion card
```

**Layer 1 — SpatialGrid.** A three-level lat/lng cell index (~5.5 / 22 /
88 km cells at the equator) built over the candidates. A radius query picks
the finest layer that covers the radius, scans only the neighboring cells,
then exact-filters by distance. Longitude spans widen with latitude, so it
stays correct far from the equator. The prefilter radius is exact in
distance mode; for walk/drive it's a generous straight-line bound
(`min × 85 m` walking, `min × 1.3 km` driving) whose only job is to spare
hopeless candidates from ETA calls.

**Session semantics.** A session = (origin, budget, candidate set). The grid
query runs **once per session**, not per refresh; refreshes just pop the
queue. The session rebuilds when the budget changes, the candidate set
changes, or the user moves more than min(2 km, radius/2) — the tolerance
shrinks with tight budgets so a 500 m radius doesn't serve stale results.

**Queue order.** Candidates are shuffled *within* distance rings (thirds of
the radius), nearest ring first: suggestions try the user's own area before
neighboring towns, so early route checks mostly pass and fewer network
calls are wasted — this is the "same city first, then nearby" behavior.

**Layer 2 — route verification.** Candidates are popped one at a time and
checked with `MKDirections.calculateETA` (Apple Maps: `.automobile` with
`departureDate = now` → traffic-aware; `.walking` for walk mode; free, no
API key). Pass = ETA ≤ budget. Distance mode does **zero** route lookups —
the grid query already was the exact answer. ETA calls are never batched
(MapKit throttles); a throttle error requeues the candidate and tells the
user to wait a minute. At most 12 route checks per refresh (6 on the Uber
tab, whose layer-3 checks are slower).

**No-repeat.** Shown places are excluded until the in-range pool is
exhausted, then the pool reshuffles (avoiding an immediate repeat of the
current card).

## Lazy loading & caching

Everything below is fetched only when first needed, and cached at the
narrowest sensible scope:

| What | When fetched | Cache & lifetime |
|---|---|---|
| Route ETA (Apple Maps) | per candidate, at suggestion time | in-memory, 10 min TTL, keyed by place + mode + origin bucketed to ~500 m (GPS jitter reuses entries) |
| In-range pool | once per engine session | lives for the session (origin/budget/candidate change rebuilds) |
| Cover photo + description | first time a place's card is shown | persisted to the store (fill-only — never overwrites source data); failures retried once per app run |
| Michelin local-script names | per Michelin-tab visit, visible rows first | persisted forever; ≤40 fetches/visit, 0.4 s apart; failures negatively cached per session |
| Uber Eats availability | per candidate, Uber tab only | verified store URL persisted to the store (next suggestion skips the check); not-found cached per session only — places can join Uber Eats later |
| Michelin dataset | bundled CSV instantly; GitHub refresh weekly | downloaded copy cached on disk (`michelin-cache.csv`); offline falls back silently |
| Google list sync | on add, on demand, and weekly per enabled list | merged into the store; a failed sync keeps the previous data |
| The store itself | — | single JSON file, saved with a 0.8 s debounce off-main; loads off-main at launch |
| Uber bot-wall clearance | first Uber check of a session | WKWebView default cookie store, persists across launches |

## External integrations

### Google Maps

- **In:** shared-list links (share sheet or pasted) are scraped — the list
  page embeds a tokenized `getlist` endpoint whose response carries each
  place's name, coordinates, and `cid`. Takeout files import the starred
  list and list CSVs. Details and wire formats: ARCHITECTURE.md.
- **Out:** tapping a card's photo (or a Michelin row) opens the place in
  Google Maps: the app's URL scheme (`comgooglemaps://`) when installed,
  web fallback otherwise. Stored `?cid=` URLs open the *exact* place;
  places without one fall back to a name+coordinates search.
- Place pages also serve as the photo/description source for non-Michelin
  places (social-preview `og:` metadata; Google's stock "no photos"
  artwork — static maps, generic geocode cards — is detected and rejected,
  showing the app's own placeholder art instead).

### Apple Maps (MapKit / CoreLocation)

- `MKDirections.calculateETA` = the walk/drive budget verifier (see engine
  layer 2). Traffic-aware, free, no API key, but throttled — hence lazy,
  serial, cached, capped.
- `CLGeocoder` resolves coordinates for Takeout CSV rows and manually added
  places (throttled, best-effort; a place can exist without coordinates —
  it's listed but excluded from distance filtering).
- `CLLocationManager` (when-in-use) supplies the origin.

### Michelin Guide

- **Dataset:** the open michelin-my-maps CSV (all tiers), bundled at build
  time, refreshed weekly from GitHub. A bundled history overlay adds
  years-on-list and former (dropped) places back to 2022.
- **Guide pages:** used two ways, both requiring a **mobile Safari
  user-agent** (michelin.com's bot filter serves desktop/CLI agents a
  challenge): local-script restaurant names from the restaurant's own
  country's edition, and card photo/description from `og:` metadata.
- The card's "View in Michelin Guide" button opens the guide edition
  matching the name-language preference.

### Uber Eats

The hardest integration — ubereats.com fronts everything with a JS bot
defense (plain HTTP clients get a challenge shell, the HTML search page
gates on a location redirect). The app therefore runs verification **inside
a hidden WKWebView**: real WebKit clears the challenge once (cookies
persist), and the checker then calls Uber's own same-origin JSON APIs from
that page — no HTML parsing:

1. `getSearchSuggestionsV1` with the restaurant's name (+ the user's
   coordinates via the `uev2.loc` cookie) → store candidates
   (uuid + title + often coordinates).
2. Candidates are fuzzy-ranked against our name (containment +
   normalized-Levenshtein; CJK-aware).
3. Geo verification: candidate coordinates (from the feed, else a
   `getStoreV1` lookup) must sit within **100 m** of our saved place, plus
   a passing name score. Location is the strong signal — name-only matching
   linked wrong branches. With no geo available at all, only a near-certain
   (≥0.85) name match passes.
4. Verified → the canonical store deep link
   (`store-browse-uuid/<uuid>?diningMode=DELIVERY`) is persisted on the
   place and the order button uses it (looked up live at tap time — the
   card's snapshot may predate verification).

Outcome semantics: *verified* → suggest with a store deep link; *real
results, no match* → drop the candidate, roll another; *couldn't tell*
(offline/bot wall) → keep the candidate and fall back to a search universal
link, so the tab still works when Uber wins. Universal links always work
regardless: iOS hands ubereats.com URLs to the installed app without any
web request.

### Share extension (Google Maps → FeedYu)

A minimal share-sheet target: accepts a URL or share text, extracts the
first link, drops it in an App Group inbox, shows a confirmation, and
closes. The main app drains the inbox on next activation, creates the list
(respecting the 20-list cap and deduping by URL), and starts syncing. The
extension itself does no networking.

## Network etiquette (bot walls & throttles)

Load-bearing constants — changing any of these breaks a source (see
ARCHITECTURE.md gotcha #5):

| Host | Requirement |
|---|---|
| maps.app.goo.gl | append `?_imcp=1` (else a JS interstitial) |
| google.com/maps | desktop Chrome UA for list pages |
| guide.michelin.com | mobile Safari UA (else HTTP 202 challenge) |
| ubereats.com | real WebKit only (WKWebView); same-origin API calls |
| Apple Maps ETA | serial, ≤12/refresh, 10-min cache, throttle-aware |
| CLGeocoder / place scrape | sequential with 0.3 s delays |
| guide.michelin.com (names) | ≤40/visit, 0.4 s apart |
