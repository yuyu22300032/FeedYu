# FeedYu (formerly DinePick)

iOS app (SwiftUI, iOS 17+, iPhone-only) suggesting tonight's restaurant from
the user's saved Google Maps places within a travel budget (straight-line
distance, walk time, or traffic-aware drive time),
plus a full Michelin guide tab (all tiers, 2022+ listing history,
local-language names). A second target, `FeedYuShare`, is a share-sheet
extension that receives Google Maps list links (App Group hand-off).
MIT licensed.

## Read before working

- `docs/MAINTENANCE.md` — **start here when something is broken**:
  symptom→cause debugging playbooks, the external-dependency risk register
  (every scraped surface and what we assume about it), fixture-recapture
  procedure, and what "verified" means in this project.
- `docs/ARCHITECTURE.md` — structure, data flow, merge/engine semantics, and
  a **"gotchas that already caused bugs"** list. Read it before structural
  changes or touching parsers.
- `docs/FEATURES.md` — page-by-page behavior, the layered suggestion
  pipeline, lazy-loading/cache strategy, and the Google Maps / Apple Maps /
  Michelin / Uber Eats integration contracts.
- `docs/REQUIREMENTS.md` — **behavior contracts mapped to their enforcing
  tests**. A PR that changes behavior updates the contract AND its test in
  the same PR; regressions found by human testing mean this file failed —
  fix the gap here too.
- `docs/DEVELOPMENT.md` — build/test/deploy commands, device data-container
  recipes, data pipeline, fixture policy, backlog.
- `PLAN.md` — original spec (historical; uses the old DinePick name).

Notes for agents: `main` is PR-only (branch ruleset) — push a feature
branch and open a PR; the auto-approve workflow
(`.github/workflows/auto-approve.yml`) satisfies the required review for
the owner's PRs, so enable auto-merge and it lands itself.
`AGENTS.md` is a symlink to this file — edit this one.
`.claude/skills/` has executable recipes: `deploy-device` (build + install
on a connected iPhone, with known failure modes) and `verify` (how to prove
a change works beyond the unit suite).

## Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # required
xcodegen generate       # after adding/removing/renaming files (project.yml is truth)
xcodebuild test -project FeedYu.xcodeproj -scheme FeedYu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test -project FeedYu.xcodeproj -scheme FeedYuDemo \
  -only-testing:FeedYuUITests/SuggestionContractUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'  # view-wiring contracts (run when views change)
python3 scripts/preprocess_michelin.py   # regenerate bundled Michelin CSVs
```

Device deploy + app-container data surgery: see docs/DEVELOPMENT.md.

## Hard rules

1. New stored properties on `Restaurant` MUST be `Optional` — non-optional
   additions silently wipe every user's persisted store on decode.
2. Data sources never crash on bad input and never delete store entries on
   failure; failures go to per-source `SyncStatus`. The only deletion path
   from sync: a *successful* complete-list source (`fetchIsCompleteList`)
   unstamps places it stopped returning — guarded to skip when the fetch
   returns less than half the previously stamped count.
3. Committed test fixtures MUST be synthetic. Real captured Google/Michelin
   responses contain account ids and personal place lists — keep them out of
   git (`.gitignore` covers `*-real.*`, Takeout exports, device stores).
4. Every user-facing string outside a SwiftUI view literal needs
   `String(localized:)` + entries in `Localizable.xcstrings` (en/zh-Hant/ja).
5. Scraper user-agents are load-bearing (michelin.com → mobile Safari UA;
   goo.gl links → append `?_imcp=1`; ubereats.com getStoreV1 → `uev2.loc`
   location cookie, else closed stores read as open). Don't "clean them up".
