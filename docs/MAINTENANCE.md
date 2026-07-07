# FeedYu Maintenance Field Manual

For whoever maintains this after the original author — human or AI agent.
This file assumes you are smart enough to run shell commands and edit Swift,
but know **nothing** about this codebase. It tells you where things break,
why, and how to prove you fixed them. Design rationale lives in
[ARCHITECTURE.md](ARCHITECTURE.md), page behavior in
[FEATURES.md](FEATURES.md), commands in [DEVELOPMENT.md](DEVELOPMENT.md).

## 60-second mental model

FeedYu is an iOS app with **no backend and no API keys**. Everything it
knows comes from four places:

1. **Google Maps saved lists** — scraped from shared-list links (share
   sheet or paste) or imported from Takeout files.
2. **The Michelin guide** — an open CSV dataset bundled + refreshed weekly,
   plus scraped guide pages for local-language names and photos.
3. **Apple MapKit** — traffic-aware ETAs (free, throttled) and geocoding.
4. **Scraped public web pages** — Google place/search pages, Uber Eats.

Everything lands in one JSON store (`RestaurantStore`, one `Restaurant`
row per physical place, merged across sources). The suggestion engine
filters by travel budget and rolls random picks. Because *every* external
surface is scraped rather than an API, **the most likely maintenance event
is: a website changed its format and some feature silently degraded.**
That's what most of this file is about.

## Orientation for a new maintainer

Read in this order (≈20 minutes):

1. `CLAUDE.md` (= `AGENTS.md`) — hard rules. Non-negotiable.
2. This file's playbooks — skim so you know what exists.
3. `docs/ARCHITECTURE.md` — especially "Gotchas that already caused bugs".
4. `docs/FEATURES.md` — when touching a specific page or integration.

Before any change: `xcodebuild test` must pass (command in DEVELOPMENT.md).
After any change: it must still pass, **and** you must exercise the changed
flow (see "Verifying a change" below). Never claim something works because
it compiles.

## Golden invariants (violating these has already destroyed user data)

These restate CLAUDE.md's hard rules with the failure you'll cause:

| Rule | What happens if you break it |
|---|---|
| New `Restaurant` stored properties must be `Optional` | The JSON decode of every existing user's store fails on launch → the app treats it as "no store" → **all saved data silently wiped**. There is no migration layer. |
| Sources never delete store entries on failure | A transient Google format change would erase the user's list. Failures must land in per-source `SyncStatus` and keep old data. |
| Committed fixtures must be synthetic | Real captures embed the author's Google account ids and personal place list. Privacy leak, permanent in git history. |
| Scraper user-agents / URL params are load-bearing | michelin.com serves HTTP 202 challenges to desktop/CLI UAs (needs mobile Safari UA); `maps.app.goo.gl` serves a JS interstitial without `?_imcp=1`; google.com/maps list pages need a *desktop* UA. "Cleaning up" these breaks scraping with no error you'll notice in tests. |
| `String(localized:)` for user-facing strings outside view literals | The string ships English-only; zh-Hant/ja users see mixed-language UI. Add entries to `Localizable.xcstrings`. |
| `project.yml` is the project source of truth | Editing `FeedYu.xcodeproj` by hand gets overwritten by the next `xcodegen generate`. Add/rename files → run `xcodegen generate`. |

## Debugging playbooks (symptom → cause → fix)

### "Tapping a place opens a Google search page, not the restaurant"

This is the **expected fallback**, not always a bug. The decision chain
(all in `Support/`):

1. `PlaceInfoFetcher.mapsURL(for:store:)` — tap entry point (Michelin rows,
   card photos). Stored **exact** URL (`?cid=`/`?ftid=`/`/maps/place/`,
   per `GoogleMapsOpener.isExactPlaceURL`) → open it directly.
2. Otherwise `GooglePlaceResolver.resolveCid` races a 2.5 s timeout:
   fetches a name search anchored at the place's coordinates, extracts
   `cid` + pin per result, picks the nearest pin within 150 m. Success →
   persisted via `store.setGoogleMapsURL` (upgrades stored search URLs,
   never overwrites exact ones) → every later tap is exact.
3. Failure/timeout → `GoogleMapsOpener.url(for:)` search fallback, using
   the local-market name when cached (`Restaurant.googleSearchName`).

So a *persistent* search-page open means resolution keeps failing. Causes,
most likely first:

- **Ambiguity guard fired** (two different places nearly equally close —
  food courts, twin branches). Deliberate: a wrong cid would be persisted
  and silently open the wrong restaurant forever. See DEVELOPMENT.md
  backlog #8 for the name-scoring upgrade path before "fixing" this.
- **Saved coordinates >150 m from Google's pin** (coarse Michelin/Takeout
  geocoding). Verify by searching the place manually in Google Maps and
  long-pressing its pin to compare coordinates.
- **Google changed the search-page wire format** — the `!1s0x…:0x…` /
  `!3d<lat>!4d<lng>` tokens moved or vanished. See "Recapturing fixtures".
- Resolution is attempted **once per session per place per search name**
  (`attemptedCidSearchNames`) — relaunch the app to retry, or a
  newly-localized name grants one fresh attempt. The Michelin tab also
  pre-warms the nearest rows in the background (`prefetchMapsURLs`, ≤12
  per visit, 1.5 s apart). Keep it throttled: hammering google.com earns
  the "unusual traffic" wall, breaking resolution *and* list sync.

To inspect what a device has stored: pull `store.json` (recipe in
DEVELOPMENT.md "App-container surgery") and check the place's
`googleMapsURL` field.

### "It opened the WRONG restaurant"

A bad cid got persisted (resolver matched an impostor, or a source
supplied it). Pull `store.json`, find the row, check `googleMapsURL` —
opening `https://maps.google.com/?cid=<value>` in a browser shows which
place it points at. Fix the data by deleting that field from the row and
pushing the store back; fix the *cause* in `GooglePlaceResolver` (consider
tightening `matchRadiusMeters`/`ambiguityMarginMeters`, with tests).

### "Shared list sync fails / returns 0 places"

Google changed the list-page or getlist format (it has before — the wire
format is documented in ARCHITECTURE.md "GoogleSharedListSource"). Check
Settings → the per-list `SyncStatus` message first. Then follow
"Recapturing fixtures" below. The parse is a tolerant regex scan
(`parsePlaces`) — usually the fix is adjusting one pattern, not a rewrite.
Canary (no app needed):

```sh
curl -sIL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126" \
  "https://maps.app.goo.gl/<any-shared-list>?_imcp=1" | head -1   # expect 200
```

### "All my restaurants disappeared after an update"

Almost certainly invariant #1 (a non-optional stored property was added to
`Restaurant`). Make the property `Optional` and ship a fix. The user's old
`store.json` is still on disk — decode failure doesn't delete the file
(verify current code kept it that way: `RestaurantStore` load path). It can
be recovered with the container-surgery recipe once the decode is fixed.

### "Michelin tab is empty / stale"

- Empty with location denied → expected (`ContentUnavailableView`).
- Empty with location on → check the dataset: the weekly refresh guard
  requires >100 parsed rows to accept a download
  (`MichelinDataSource.refreshFromRemote`); a broken upstream CSV falls
  back to the cache/bundle silently. Delete
  `Application Support/FeedYu/michelin-cache.csv` to force the bundled
  snapshot. Upstream: `ngshiheng/michelin-my-maps` on GitHub — if that repo
  moves or dies, `remoteURL` needs a new home and
  `scripts/preprocess_michelin.py` needs its history source updated.
- Award tier names changed upstream → `MichelinAward(datasetValue:)`.

### "Local-language names aren't appearing"

`MichelinNameLocalizer` fetches ≤40 names per screen visit, 0.4 s apart,
skipping past failures for the session. If *nothing* localizes: michelin.com
bot filter (needs the **mobile Safari UA** — test with curl and both UAs;
desktop gets HTTP 202), or the guide-page `<title>` format changed
(`parseTitleName`). Names cache permanently in the store once fetched.

### "Cards show no photo/description"

`PlaceInfoFetcher` scrapes `og:` meta from the Michelin guide page (if the
place has one) else the Google place page. It negative-caches per session
(`attemptedIDs`) and deliberately rejects Google's generic artwork
(`isGenericImage`: staticmap / default_geocode / tactile) — a fork-and-knife
placeholder can be *correct* (place genuinely has no photos). Only debug if
places that show photos on google.com show none in the app.

### "Uber Eats button opens a search instead of the store page"

The checker (`UberEatsChecker`) matched no store within 100 m + name
similarity ≥ 0.5. Same trade-off as the cid resolver: no link beats a wrong
link. Format canaries live in its fixture tests.

### "Suggestions are slow / ETAs missing"

`MKDirections` is throttled by Apple — the engine checks candidates
lazily/serially and caches ETAs per session on purpose (ARCHITECTURE.md
"Engine"). Distance mode does zero route lookups. Don't "optimize" by
parallelizing ETA requests; Apple starts erroring and everything gets slower.

### "App won't launch on the phone anymore" (was fine last week)

Free-account code signing expires after **7 days**. Rebuild + reinstall
(user data survives). See DEVELOPMENT.md.

### Simulator tests fail with "Busy / failed preflight checks"

Environment flake, not your change: `xcrun simctl shutdown all`, wait a few
seconds, rerun. If `xcodebuild` can't find tools at all, you forgot
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## External-dependency risk register

Every remote surface, what we assume about it, and where the assumption is
encoded. When a feature degrades with no code change — check here first.

| Surface | Assumption | Encoded in | Symptom when it breaks |
|---|---|---|---|
| `maps.app.goo.gl/<list>` | `?_imcp=1` skips interstitial; desktop UA | `GoogleSharedListSource` | list sync fails |
| `google.com/maps/preview/…getlist` | `)]}'`-prefixed JS array; coords→id-pair→name adjacency | `GoogleSharedListSource.parsePlaces` | sync returns 0/garbage |
| `google.com/maps/search/…` HTML | `0x…:0x<cid-hex>` + `!3d!4d` pin tokens per result; desktop UA | `GooglePlaceResolver` | taps stay on search fallback |
| Google place pages | `og:image`/`og:description` meta present | `PlaceInfoFetcher` | photos vanish for non-Michelin places |
| guide.michelin.com | mobile Safari UA passes bot filter; locale editions share slugs; `<title>` = "Name – City …" | `MichelinNameLocalizer`, `PlaceInfoFetcher` | no local names / no Michelin photos |
| michelin-my-maps (GitHub raw CSV) | column names (Name/Award/Latitude/…); >100 rows | `MichelinDataSource` | dataset stales silently (falls back to cache) |
| Uber Eats pages/API | store links/JSON-LD geo in feed & store pages | `UberEatsChecker` | order button degrades to search |
| MKDirections | throttled but free | `SuggestionEngine` | ETAs slow/missing if abused |

## Recapturing fixtures after a format change (privacy-critical)

The full policy is in DEVELOPMENT.md "Test fixtures policy". Short version:

1. Capture the real page/response to `/tmp` or a `*-real.*` filename
   (both gitignored). Curl recipes are in DEVELOPMENT.md.
2. Fix the parser against the real capture.
3. Rewrite the **synthetic** fixture in `FeedYuTests/Fixtures/` to mirror
   the new structure byte-for-byte with fake ids/names.
4. `git grep` for account ids / list tokens before committing. Real
   captures in git history are unremovable — treat this as a release gate.

## Verifying a change (what "done" means here)

1. `xcodebuild test …` passes (78+ tests; pure logic, fast).
2. Exercise the changed flow for real — unit tests here cover parsers and
   engine logic, **not** live scraping or UI wiring. Use the simulator
   smoke-test recipe (seeded store + fake location, DEVELOPMENT.md) or a
   device build. Claude Code users: the `verify` and `deploy-device`
   project skills in `.claude/skills/` script both.
3. Per-area minimum checks:
   - Parsers/scrapers → run against a fresh *real* capture, not just fixtures.
   - `Restaurant`/store changes → decode an existing `store.json` (invariant #1!).
   - Suggestion engine → Tonight tab: roll, re-roll, switch budget modes.
   - Maps/link opening → tap targets on Tonight AND Michelin tabs (they
     share `RestaurantCard` but rows differ).
   - Localized strings → launch with `-AppleLanguages "(zh-Hant)"` / `"(ja)"`.
4. Update the docs you just falsified: FEATURES.md for behavior contracts,
   ARCHITECTURE.md gotchas for anything that bit you, this file for new
   failure modes. The gotchas list is the project's institutional memory —
   append, don't prune.
