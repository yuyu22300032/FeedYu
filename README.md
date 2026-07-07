# FeedYu

Formerly “DinePick”. iPhone app that suggests a restaurant for tonight from
your saved Google Maps places, within a travel budget you pick right on the
page: straight-line distance (200 m–50 km, no route lookups), walking time,
or driving time in current traffic. A Michelin tab (all tiers) does the same
with price/award filters. An Uber Eats tab suggests from the same lists
(distance-only constraint), verifies each pick is actually orderable on
Uber Eats near you (matched by location within 100 m + fuzzy name), and its
order button deep-links straight into the verified store, ready to order.
Suggestion cards show a cover photo and description
(scraped lazily from the place's Michelin or Google Maps page); tapping the
photo opens Google Maps to confirm hours and live traffic. Manage up to 20
saved lists — your own and friends' — toggleable, renameable, and removable
in Settings (removal never deletes places that are also on another list),
and add new ones by sharing a Google Maps list link straight to FeedYu from
the share sheet. Swipe left/right to move between tabs.
Full spec and decisions: [PLAN.md](PLAN.md) (original, historical).

**Documentation:** [docs/FEATURES.md](docs/FEATURES.md) (what each page does,
the suggestion pipeline, lazy loading & caching, and the Google Maps / Apple
Maps / Michelin / Uber Eats integrations),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (structure, data flow, design
rules, known gotchas), and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
(build/test/deploy workflows, data pipeline, fixture policy, enhancement
backlog). `CLAUDE.md` orients AI coding sessions.

## Getting it running (one-time setup)

1. **Install Xcode** (not currently on this Mac — only Command Line Tools):
   App Store → Xcode, then run once and accept the license.
   If `xcodebuild -version` still complains:
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. Open `FeedYu.xcodeproj`, select the **FeedYu** target → Signing &
   Capabilities → choose your personal team (free Apple ID works; app re-signs
   every 7 days).
3. Plug in your iPhone, pick it as the run destination, press Run.
   First run: on the phone, Settings → General → VPN & Device Management →
   trust your developer certificate.

Run the unit tests with **⌘U** (parser/merge/engine tests, including the
shared-list scraper against a saved HTML fixture).

## Day-to-day data setup (in the app's Settings tab)

- **Want to go / custom lists (automatic sync):** Google Maps → Saved → your
  list → Share → pick **FeedYu** in the share sheet (or copy the link and
  paste it under *Add a Google Maps shared list*). Works for friends' shared
  lists too — up to 20 lists, each toggleable in Settings so you can try one
  out without mixing it into your regulars. (Google doesn't allow sharing
  the Starred list.)
- **Starred places:** [takeout.google.com](https://takeout.google.com) →
  deselect all → *Maps (your places)* + *Saved* → export, unzip, then import
  `Saved Places.json` here. List CSVs (e.g. `Want to go.csv`) can be imported
  too; their rows have no coordinates, so resolution takes a minute.
- **Michelin data** works out of the box (bundled snapshot, auto-refreshes
  weekly from [michelin-my-maps](https://github.com/ngshiheng/michelin-my-maps)).
  All award tiers are included (Selected/Plate, Bib Gourmand, 1–3 stars), plus
  a bundled history overlay (`michelin_history.csv`, built from yearly dataset
  snapshots 2022–2026) that shows each place's listed years and lets the
  Michelin tab include former (dropped) entries. Note: 2022–2023 snapshots
  only tracked stars+Bib, so Selected places show years from 2024 on.
  Michelin restaurant names display in a language you pick in Settings
  (local/EN/中文/日本語) — local-script names are fetched lazily from the
  Guide's locale editions and cached in the store.

## Project layout

- `FeedYu/` — app sources (SwiftUI, iOS 17+). Data sources implement the
  `RestaurantDataSource` protocol and sync into `RestaurantStore` (JSON in
  Application Support); the fragile Google scraper can only ever break its own
  sync, never the app.
- `FeedYuTests/` — unit tests; `Fixtures/sharedlist.html` is the scraper
  fixture. When Google changes their page format, save the new HTML from a
  shared-list URL as the fixture and fix `GoogleSharedListSource.parsePlaces`
  until tests pass.
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec;
  after adding/removing files run `xcodegen generate` (already installed).
- `scripts/preprocess_michelin.py` regenerates both bundled Michelin CSVs
  (see docs/DEVELOPMENT.md).

## Languages

The UI is localized in English, 繁體中文（台灣）and 日本語
(`FeedYu/Resources/Localizable.xcstrings` — add languages there). Restaurant
names from your shared Google lists are scraped in the device language
(`Accept-Language`), so they arrive in the local script; re-run Sync Now after
changing the device language to re-fetch names. The Michelin dataset only
ships romanized names, but the card's Michelin Guide button opens the
tw/zh_TW or jp/ja edition, and Google Maps itself shows local names.
Note: a place saved with a local-script name (鮨さいとう) won't auto-merge
with its romanized Michelin entry (Sushi Saito) — the dedupe key is
name+coords, so both may appear until one is hidden.

## License & data attribution

FeedYu is open source under the **MIT License** (see [LICENSE](LICENSE)) —
App Store-friendly, so anyone can build on or ship it. It has no third-party
code dependencies (Apple system frameworks only).

Bundled data (`FeedYu/Resources/michelin.csv`, `michelin_history.csv`) is
derived from [michelin-my-maps](https://github.com/ngshiheng/michelin-my-maps)
by Jerry Ng, MIT License. The underlying restaurant facts originate from
guide.michelin.com; treat the data as reference material, not something this
license can grant rights over. Anyone shipping this to the App Store should
also review the Google Maps and Michelin terms around the scraping features
(`GoogleSharedListSource`, `MichelinNameLocalizer`) — fine for personal use,
worth a legal look for mass distribution.

Privacy notes for contributors:
- Never commit Takeout exports or real captured Google/Michelin responses —
  they contain account IDs and personal place lists. `.gitignore` covers the
  usual paths; test fixtures must be synthetic (see `FeedYuTests/Fixtures/`).
- `project.yml` contains an Apple Development Team ID. That's not a secret
  (it's embedded in every built app), but fork users should replace it with
  their own.

## Known limitations (by design — see PLAN.md)

- Open hours aren't checked in-app (no Google API key); tapping the card's
  cover photo opens Google Maps to confirm hours and traffic.
- Cover photos and descriptions are scraped best-effort from the place's
  Michelin/Google page metadata — some places show a placeholder image and
  no text, and Google's description line is thin (rating · price · category).
- Shared-list scraping is best-effort; failures show per-source status in
  Settings while the app keeps serving its local store.
- **Verify the scraper against your real shared-list link on first run** — it
  has only been tested against a synthetic fixture.
