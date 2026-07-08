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

## Shipping to the App Store

Metadata (descriptions en/zh-Hant/ja, keywords, privacy-label answers,
reviewer notes) is paste-ready in [APPSTORE.md](APPSTORE.md). The developer
holds written permission from Google and Uber for the page usage — attach
those emails if App Review raises guideline 5.2.2.

One-time setup (browser/GUI, can't be scripted):

1. **Xcode → Settings → Accounts** — after enrolling, reopen the Apple ID
   account so the paid team appears; then put its Team ID in `project.yml`
   (both targets' `DEVELOPMENT_TEAM`) and `xcodegen generate`. The old
   `84336L2H62` is the free personal team — it cannot distribute.
2. **GitHub repo → Settings → Pages** — deploy from branch `main`, folder
   `/docs`. This publishes the privacy policy
   (https://yuyu22300032.github.io/FeedYu/privacy.html) and the guide.
3. **appstoreconnect.apple.com → My Apps → "+"** — New App: iOS, name
   FeedYu, bundle `com.yuyu.FeedYu` (register the ID when prompted),
   SKU `feedyu-ios`. Fill the listing from APPSTORE.md; upload the
   screenshots from the capture recipe below.

Per release:

4. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`,
   `xcodegen generate`, run the test suite.
5. Xcode: destination "Any iOS Device" → Product → **Archive** →
   Distribute App → App Store Connect (creates the Distribution cert on
   first run).
6. App Store Connect: pick the build, TestFlight first (external-link beta
   needs a short review), then Submit for Review with the notes from
   APPSTORE.md.

### Screenshot capture (any tab, scripted)

`-initialTab michelin|ubereats|settings` opens the app on that tab —
the simulator can't tap the tab bar, this launch argument is the hook.
Seed the simulator with a device store + prefs for real-looking data
(container-surgery recipes above; prefs must go through
`simctl spawn <device> defaults import com.yuyu.FeedYu <plist>` — copying
the plist file directly is silently clobbered by cfprefsd). Capture on an
iPhone 17 Pro Max class simulator (1320×2868 = the required 6.9" size)
with `simctl io <device> screenshot`. Keep screenshots out of git — they
show personal lists.

### Longer-term release notes

- The scraping features are ToS-gray for *mass* distribution even with
  written permission — if scale ever matters, the clean path is the Google
  Places API; `RestaurantDataSource` was designed so that's an
  add-a-source change, not a rewrite.

## Enhancement backlog (known gaps, in rough priority)

1. Cross-script dedupe: 鮨さいとう (from Google) vs Sushi Saito (Michelin)
   don't merge — see ARCHITECTURE.md "Store" for constraints and ideas.
2. Open-hours checking (needs Places API or scraping; deliberately punted).
3. Zip import for Takeout (needs a minizip dependency or iOS gaining an API).
4. Starred places only update via manual Takeout re-import.
5. Michelin name prefetch could batch smarter (currently ≤40/visit).
6. Store file could move to SwiftData if it outgrows JSON (fine at ~25k rows).
7. History overlay ships in the bundle only — could auto-refresh yearly.
8. `GooglePlaceResolver` refuses ambiguous matches (two different places
   nearly equally close — food courts, twin branches) instead of guessing.
   Upgrade path: extract result *names* from the search page and combine
   pin distance with `UberEatsChecker.similarity` (like the Uber matcher's
   distance ≤100 m + score ≥0.5 rule) to disambiguate instead of refusing.
   Costs a new tolerant name scanner over the search-page blob (fragile
   when Google changes format) and must keep pins primary — names lie
   (romanization/translation), which is why the resolver is pins-only today.
