# FeedYu Development Guide

Practical workflows: building, testing, deploying, data pipelines, and the
enhancement backlog. Architecture and design rationale live in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Prerequisites

- Xcode 26+ (`xcodegen` via Homebrew for project regeneration).
- If `xcode-select` still points at CommandLineTools, prefix commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or run
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once.
- `project.yml` is the source of truth for the Xcode project. After adding,
  removing, or renaming files: `xcodegen generate` (the committed
  `FeedYu.xcodeproj` is a build artifact of it). Signing team is set there
  (`DEVELOPMENT_TEAM`) — fork users replace it with their own.

## Build & test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Full test suite (also builds the app target)
xcodebuild test -project FeedYu.xcodeproj -scheme FeedYu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Or ⌘U in Xcode. Tests are pure-logic (parsers, merge, engine queue) — no
network, no location; the engine tests inject a fake `etaProvider`.

### Simulator smoke test with location + seeded data

```sh
xcrun simctl boot "iPhone 17 Pro" && xcrun simctl bootstatus booted -b
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/FeedYu.app
xcrun simctl privacy booted grant location com.yuyu.FeedYu
xcrun simctl location booted set 25.0330,121.5654        # Taipei
# Optionally seed restaurants before first launch:
#   write store.json into "$(xcrun simctl get_app_container booted \
#   com.yuyu.FeedYu data)/Library/Application Support/FeedYu/"
xcrun simctl launch booted com.yuyu.FeedYu
xcrun simctl io booted screenshot /tmp/shot.png
# Launch in a specific language:
xcrun simctl launch booted com.yuyu.FeedYu -AppleLanguages "(zh-Hant)" -AppleLocale zh_TW
```

## Deploying to a physical iPhone (CLI, no Xcode GUI)

One-time: Developer Mode on the phone (Settings → Privacy & Security), trust
the computer, trust the developer cert on first launch (Settings → General →
VPN & Device Management).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun devicectl list devices                    # get the device UUID
DEV=<device-uuid>

# Also signs/embeds the FeedYuShare extension and registers the
# group.com.yuyu.FeedYu App Group (works on a free personal team).
xcodebuild -project FeedYu.xcodeproj -scheme FeedYu \
  -destination "platform=iOS,id=$DEV" -allowProvisioningUpdates build
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/FeedYu-*/Build/Products/Debug-iphoneos/FeedYu.app)
xcrun devicectl device install app --device $DEV "$APP"
xcrun devicectl device process launch --device $DEV com.yuyu.FeedYu
```

Free-account signing expires after **7 days** — the app stops launching;
re-run build+install (data survives). A paid developer account extends this
to a year and is required for App Store/TestFlight.

### App-container surgery (backup / restore / migrate user data)

Works for development-signed apps; terminate the app first (a live app will
re-save its in-memory store over what you push):

```sh
# Pull the store
xcrun devicectl device copy from --device $DEV \
  --domain-type appDataContainer --domain-identifier com.yuyu.FeedYu \
  --source "Library/Application Support/FeedYu/store.json" --destination ./store.json
# Push it back
xcrun devicectl device copy to --device $DEV \
  --domain-type appDataContainer --domain-identifier com.yuyu.FeedYu \
  --source ./store.json --destination "Library/Application Support/FeedYu/store.json"
# Preferences plist (settings, shared-list configs) lives at
#   Library/Preferences/com.yuyu.FeedYu.plist
```

This is also the bundle-id migration recipe (used for DinePick → FeedYu):
install the new app, launch once (creates directories), terminate, pull from
the old container, push into the new one, relaunch, verify, uninstall old.

## Michelin data pipeline

`FeedYu/Resources/michelin.csv` (current guide, all award tiers) and
`michelin_history.csv` (listed-years overlay + former places) are generated
by:

```sh
python3 scripts/preprocess_michelin.py        # writes both CSVs in place
```

The script downloads the current dataset plus the latest snapshot of each
calendar year (2022+) from the michelin-my-maps repo's git history (GitHub
API, no auth), clusters places by normalized name + 500 m, and derives the
per-place year ranges. Downloads are cached in `.michelin-cache/`
(gitignored). Notes:

- Years are only as granular as the yearly snapshots; 2022–2023 snapshots
  tracked stars+Bib only, so Selected places show years from 2024 on.
- Re-running after a guide update changes both files; the in-app weekly
  refresh only updates the *current* list — history requires a new app build.

## Test fixtures policy (privacy-critical)

Committed fixtures MUST be synthetic. Real captured pages/responses contain
account ids, list tokens, and personal place lists. When Google/Michelin
change formats:

1. Capture the real page/response locally (keep it in `/tmp` or name it
   `*-real.*` — gitignored either way).
2. Fix the parser against the real capture.
3. Update the synthetic fixture in `FeedYuTests/Fixtures/` to mirror the new
   structure byte-for-byte with fake names/ids, and update the tests.
4. Verify with `git grep` that no account ids/list tokens are staged.

Useful capture commands (UAs matter — see ARCHITECTURE.md gotchas):

```sh
# Shared list page (desktop UA + _imcp=1), then the getlist XHR it references
curl -sL -A "Mozilla/5.0 (Macintosh...) Chrome/126" -H "Accept-Language: zh-TW" \
  "https://maps.app.goo.gl/<list>?_imcp=1" -o page.html
grep -oE 'entitylist/getlist\?[^"]*' page.html   # → fetch under /maps/preview/
# Michelin guide page needs a MOBILE Safari UA (desktop gets HTTP 202)
```

## Release / App Store path (future)

- MIT license: no obstacle. Needed: paid Apple Developer account, App Store
  Connect listing, privacy label (everything is on-device; location is used
  but not collected).
- The scraping features (`GoogleSharedListSource`, `MichelinNameLocalizer`)
  are ToS-gray for mass distribution — the clean public-release path is the
  Google Places API (per-user API keys or a backend) for lists + open hours.
  The `RestaurantDataSource` protocol was designed so this is an add-a-source
  change, not a rewrite.
- App icon, launch screen polish, and onboarding are still template-default.

## Enhancement backlog (known gaps, in rough priority)

1. Cross-script dedupe: 鮨さいとう (from Google) vs Sushi Saito (Michelin)
   don't merge — see ARCHITECTURE.md "Store" for constraints and ideas.
2. Open-hours checking (needs Places API or scraping; deliberately punted).
3. Zip import for Takeout (needs a minizip dependency or iOS gaining an API).
4. Starred places only update via manual Takeout re-import.
5. Michelin name prefetch could batch smarter (currently ≤40/visit).
6. Store file could move to SwiftData if it outgrows JSON (fine at ~25k rows).
7. History overlay ships in the bundle only — could auto-refresh yearly.
