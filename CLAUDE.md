# FeedYu (formerly DinePick)

iOS app (SwiftUI, iOS 17+, iPhone-only) suggesting tonight's restaurant from
the user's saved Google Maps places within a travel budget (straight-line
distance, walk time, or traffic-aware drive time),
plus a full Michelin guide tab (all tiers, 2022+ listing history,
local-language names). A second target, `FeedYuShare`, is a share-sheet
extension that receives Google Maps list links (App Group hand-off).
MIT licensed.

## Read before working

- `docs/ARCHITECTURE.md` — structure, data flow, merge/engine semantics, and
  a **"gotchas that already caused bugs"** list. Read it before structural
  changes or touching parsers.
- `docs/FEATURES.md` — page-by-page behavior, the layered suggestion
  pipeline, lazy-loading/cache strategy, and the Google Maps / Apple Maps /
  Michelin / Uber Eats integration contracts.
- `docs/DEVELOPMENT.md` — build/test/deploy commands, device data-container
  recipes, data pipeline, fixture policy, backlog.
- `PLAN.md` — original spec (historical; uses the old DinePick name).

## Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # required
xcodegen generate       # after adding/removing/renaming files (project.yml is truth)
xcodebuild test -project FeedYu.xcodeproj -scheme FeedYu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
python3 scripts/preprocess_michelin.py   # regenerate bundled Michelin CSVs
```

Device deploy + app-container data surgery: see docs/DEVELOPMENT.md.

## Hard rules

1. New stored properties on `Restaurant` MUST be `Optional` — non-optional
   additions silently wipe every user's persisted store on decode.
2. Data sources never crash on bad input and never delete store entries;
   failures go to per-source `SyncStatus`.
3. Committed test fixtures MUST be synthetic. Real captured Google/Michelin
   responses contain account ids and personal place lists — keep them out of
   git (`.gitignore` covers `*-real.*`, Takeout exports, device stores).
4. Every user-facing string outside a SwiftUI view literal needs
   `String(localized:)` + entries in `Localizable.xcstrings` (en/zh-Hant/ja).
5. Scraper user-agents are load-bearing (michelin.com → mobile Safari UA;
   goo.gl links → append `?_imcp=1`). Don't "clean them up".
