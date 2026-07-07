---
name: verify
description: Verify a FeedYu change actually works - run the unit suite, then exercise the affected flow in the simulator (seeded data + fake location) or on device. Use before committing or claiming a change works.
---

# Verify a FeedYu change

Compiling is not verification. Unit tests here cover parsers, store merge,
and engine logic — they do NOT cover live scraping, SwiftUI wiring, or
Google/Michelin/Uber format drift. Do both layers:

## 1. Unit suite (always)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project FeedYu.xcodeproj -scheme FeedYu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

- Failure "Busy / failed preflight checks" = simulator flake, not the
  change: `xcrun simctl shutdown all`, wait ~5 s, rerun.
- To check specific cases ran, query the `.xcresult` named at the end of
  the output (`xcrun xcresulttool get test-results tests --path <bundle>`).

## 2. Exercise the changed flow

Simulator with location + seeded data (full recipe with store-seeding in
docs/DEVELOPMENT.md "Simulator smoke test"):

```sh
xcrun simctl boot "iPhone 17 Pro" && xcrun simctl bootstatus booted -b
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/FeedYu.app
xcrun simctl privacy booted grant location com.yuyu.FeedYu
xcrun simctl location booted set 25.0330,121.5654   # Taipei = dense Michelin data
xcrun simctl launch booted com.yuyu.FeedYu
xcrun simctl io booted screenshot /tmp/shot.png     # read the screenshot to SEE the result
```

For flows needing real Google/Michelin responses or the Maps app (link
opening, scraping), a device build is the honest test — use the
`deploy-device` skill and tell the user what to tap and what they should
observe.

## Per-area minimum checks

- **Parsers/scrapers** — run against a *fresh real capture* (curl recipes in
  docs/DEVELOPMENT.md; keep captures out of git), not only fixtures.
- **Restaurant model / store** — new stored properties MUST be Optional;
  prove an existing store.json still decodes.
- **Maps link opening** — tap targets on BOTH tabs: Michelin rows and the
  card photo (Tonight + Michelin share RestaurantCard, rows differ).
- **Engine/budget** — Tonight tab: roll, re-roll, switch all three budget
  modes.
- **Localization** — `xcrun simctl launch booted com.yuyu.FeedYu
  -AppleLanguages "(zh-Hant)"` (and `"(ja)"`) if strings changed.

## 3. Close the loop

Report what was exercised and what was observed, including failures.
Update docs/FEATURES.md (behavior contracts), docs/ARCHITECTURE.md gotchas
(anything that bit you), docs/MAINTENANCE.md (new failure modes).
