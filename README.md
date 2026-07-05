# DinePick

iPhone app that suggests a restaurant for tonight from your saved Google Maps
places, reachable within your drive-time budget in current traffic — plus a
Michelin tab (stars + Bib Gourmand) with a price-band random suggester.
Suggestions open in Google Maps where you confirm hours and live traffic.
Full spec and decisions: [PLAN.md](PLAN.md).

## Getting it running (one-time setup)

1. **Install Xcode** (not currently on this Mac — only Command Line Tools):
   App Store → Xcode, then run once and accept the license.
   If `xcodebuild -version` still complains:
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. Open `DinePick.xcodeproj`, select the **DinePick** target → Signing &
   Capabilities → choose your personal team (free Apple ID works; app re-signs
   every 7 days).
3. Plug in your iPhone, pick it as the run destination, press Run.
   First run: on the phone, Settings → General → VPN & Device Management →
   trust your developer certificate.

Run the unit tests with **⌘U** (parser/merge/engine tests, including the
shared-list scraper against a saved HTML fixture).

## Day-to-day data setup (in the app's Settings tab)

- **Want to go list (automatic sync):** Google Maps → Saved → your list →
  Share → copy link → paste into *Google Maps shared lists*. (Google doesn't
  allow sharing the Starred list.)
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

- `DinePick/` — app sources (SwiftUI, iOS 17+). Data sources implement the
  `RestaurantDataSource` protocol and sync into `RestaurantStore` (JSON in
  Application Support); the fragile Google scraper can only ever break its own
  sync, never the app.
- `DinePickTests/` — unit tests; `Fixtures/sharedlist.html` is the scraper
  fixture. When Google changes their page format, save the new HTML from a
  shared-list URL as the fixture and fix `GoogleSharedListSource.parsePlaces`
  until tests pass.
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec;
  after adding/removing files run `xcodegen generate` (already installed).
- Regenerate `DinePick/Resources/michelin.csv` with the script in PLAN.md.

## Languages

The UI is localized in English, 繁體中文（台灣）and 日本語
(`DinePick/Resources/Localizable.xcstrings` — add languages there). Restaurant
names from your shared Google lists are scraped in the device language
(`Accept-Language`), so they arrive in the local script; re-run Sync Now after
changing the device language to re-fetch names. The Michelin dataset only
ships romanized names, but the card's Michelin Guide button opens the
tw/zh_TW or jp/ja edition, and Google Maps itself shows local names.
Note: a place saved with a local-script name (鮨さいとう) won't auto-merge
with its romanized Michelin entry (Sushi Saito) — the dedupe key is
name+coords, so both may appear until one is hidden.

## License & data attribution

DinePick is open source under the **MIT License** (see [LICENSE](LICENSE)) —
App Store-friendly, so anyone can build on or ship it. It has no third-party
code dependencies (Apple system frameworks only).

Bundled data (`DinePick/Resources/michelin.csv`, `michelin_history.csv`) is
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
  usual paths; test fixtures must be synthetic (see `DinePickTests/Fixtures/`).
- `project.yml` contains an Apple Development Team ID. That's not a secret
  (it's embedded in every built app), but fork users should replace it with
  their own.

## Known limitations (by design — see PLAN.md)

- Open hours aren't checked in-app (no Google API key); the card's button
  opens Google Maps to confirm hours and traffic.
- Shared-list scraping is best-effort; failures show per-source status in
  Settings while the app keeps serving its local store.
- **Verify the scraper against your real shared-list link on first run** — it
  has only been tested against a synthetic fixture.
