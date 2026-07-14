# FeedYu Behavior Requirements

The behavioral contracts of the app, each mapped to what enforces it.
This document exists because two regressions shipped to a device and were
found by human testing (2026-07-11: the suggestion pane opened dead; the
initial Uber card skipped the open check). That must not happen again.

**The rule: a PR that changes behavior updates the contract here AND its
enforcing test in the same PR.** A contract without a unit test says
explicitly how it IS verified — "sim recipe" means the `verify` skill's
simulator walkthrough; "device" means it needs the real phone. Those
tiers are debt.

View-wiring contracts run as XCUITests (`SuggestionContractUITests`,
backed by the DEBUG `-uiTestSeed` hook in `UITestSeed.swift` — synthetic
store, fixed location, no network in assertions). Slower than the unit
suite, so they live in the UI-test scheme:

```sh
xcodebuild test -project FeedYu.xcodeproj -scheme FeedYuDemo \
  -only-testing:FeedYuUITests/SuggestionContractUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Suggestion pipeline (Tonight · Michelin · Uber Eats)

| Contract | Enforced by |
|---|---|
| **Panes are eager.** Opening the app or a tab with no card up auto-rolls one as soon as the store is loaded and location is known. Never gate the auto-roll on leftover UI state (`statusMessage` gating shipped the dead-pane regression). | UI: `testColdLaunchLandsOnACardWithZeroTaps` |
| Changing any constraint (budget, price/award filters, former-toggle) revalidates a current card — it stays if it still fits (traffic minutes refreshed in place), is replaced if not — and with NO card up, rolls a fresh one. Budget changes within a slider drag coalesce (~300 ms debounce) into one revalidation of the settled value: on the Uber tab each revalidation is a live open check, so a drag across the presets must cost one check, not one per step. The debounce is a coalescer, never a gate — it always fires. | engine: `testRevalidateKeepsFittingPickAndRefreshesTraffic`, `testRevalidateReplacesWhenCurrentLeavesCandidateSet`, `testRevalidateRollsReplacementWhenOverBudget`, `testRevalidateSwitchesTravelLineWithTheMode`; UI: `testBudgetChangeWithNoCardRollsOne` |
| Hiding a restaurant replaces the current card immediately (card context menu, Michelin rows); hides from Manage are caught on tab return. | engine: `testRevalidateReplacesWhenCurrentLeavesCandidateSet`; UI: `testHideReplacesTheCardImmediately` |
| **The card's photo and description always belong to the restaurant shown.** In-place replacements must not reuse the previous card's state, and a replaced card's in-flight fetch must never land its result (shipped: a curry place wearing a mochi shop's photo after a budget change). | structural: per-restaurant view identity (`.id(suggestion.id)`) + `Task.isCancelled` guard in `RestaurantCard`; visual tier: sim recipe (image content isn't XCUITest-assertable) |
| No repeats until the in-range pool is exhausted; a drained queue wraps the rotation in place rather than demanding an extra press. | `testNoRepeatsUntilPoolExhausted`, `testRotationWrapsInsteadOfDemandingAnExtraPress` |
| Distance mode performs zero route lookups and is exact; walk/drive verify routes one candidate at a time, never batched (MapKit throttles). | `testDistanceModeMakesNoRouteCalls`, `testDistanceModeIsExact`, `testWalkingModeVerifiesWithWalkingRoutes`, `testStraightLinePrefilterExcludesHopelesslyFar` |
| Uber scans run in bounded batches (25 slow checks per press) that RESUME mid-queue; a pause says "Checked many stores — refresh to keep looking" and the tab never claims "no results" while unchecked candidates sit in the queue. Known-notFound places are skipped for free. | `testCappedScanResumesAcrossRefreshes`, `testUncappedBudgetChecksEveryPlaceInOneRefresh`, `testQuickRejectIsFreeAndDoesNotExhaustBudget` |
| Cancellation (leaving the tab) stops a scan at the next candidate, keeps queue position, and is silent — never reported as a network error, never loses the in-flight candidate. | `testCancelledRefreshStopsScanning`, `testCancellationDuringETAIsSilentAndKeepsTheCandidate`; structural: TonightView and MichelinView track every engine-touching task in `refreshTask`, cancelling the previous slot before reassigning (a revalidation runs its awaits without setting `isSearching`, so the slot may be live) and cancelling on tab leave |
| ETAs are cached 10 min per place+mode+origin-bucket; mode switches don't cross-serve. | `testETACacheAvoidsDuplicateCalls`, `testModeSwitchInvalidatesSessionAndETACache` |

## Uber Eats orderability

| Contract | Enforced by |
|---|---|
| **The Order button is a promise.** A known store's OPEN state is re-verified live on every shown suggestion — never served from a cache (product decision; a 10-minute-old "open" can be closed by now). | `testOpenVerdictIsNeverCachedForKnownStores` |
| A closed store is skipped, and the closed verdict is cached until Uber's own reopen time (it can't go stale in the wrong direction). | `testClosedVerdictIsCachedUntilReopenTime`, `testCachedVerdictFreshness`, `testParsesNextOpenTime` |
| **Merchant-paused stores are skipped too** ("the store indicated they aren't available"): `storeAvailablityStatus.state` deny-list (NOT_ACCEPTING_ORDERS, STORE_CLOSED) catches pauses that the schedule signal misses (`nextOpenTime` is null mid-shift). No reopen moment → the 10-minute recheck applies (session cache and persisted stamp both). Unrecognized states fail OPEN, logged in DEBUG to collect the vocabulary. | `testMerchantPausedStoreIsClosedWithoutReopenTime`, `testMerchantPausedKnownStoreIsSkippedEndToEnd`, `testUnrecognizedStateFailsOpen`, `testParsesAvailabilityStateBothSpellings`, `testCachedMerchantPauseExpiresAfterTTL`, `testScheduleClosedStoreCarriesReopenTime` |
| **The open check carries the user's location** (`uev2.loc`, the same payload the search pipeline sends). A location-less getStoreV1 masks schedule closure behind `TOO_FAR_TO_DELIVER` with a null `nextOpenTime` — BOTH closed signals vanish and the check fails open (shipped 2026-07-14: the cookie is session-scoped and only the search pipeline set it, so a cold launch's known-store checks ran blind and a 22:00-opening store reached the lunch card). | `testKnownStoreOpenCheckSendsTheLocation` |
| **The closed suppression persists across launches** (`uberEatsClosedUntil`; 10-min fallback when Uber gave no reopen time) and is skipped for FREE via quickReject — an afternoon of closed restaurants must not cost one live check each per launch. The stamp only ever SUPPRESSES: once past, the live open check decides again, so it can never surface a closed store. Cleared by a verified open. | `testPersistedClosedSuppressionSkipsTheLiveCheck`, `testExpiredSuppressionGoesBackToLiveChecking`, `testClosedUntilPersistsWithFallbackAndClearsOnOpen` |
| The open check survives a cold-start transport failure with exactly one retry (the app's first WebView call is this check when the Uber tab auto-rolls at launch). | `testColdStartRetryRecoversTheOpenCheck` |
| After the retry the check fails OPEN — a bot wall must not hide the user's verified neighborhood — and the fail is logged for device consoles. | `testFailsOpenOnlyAfterRetryAlsoFails` |
| Verdicts are per-restaurant-id; same-named chain branches never share a verdict or a store URL. | structural (cache keyed by `UUID`); flow tests above run per-id |
| Store matching is geo-anchored: feed geo ≤100 m + name ≥0.5, else ≥0.85 name-only; verified links use the canonical `store-browse-uuid` form; a verified notFound persists with a 7-day cooldown; `unknown` (bot wall) is never persisted and degrades to a search link. | `testParsesEmbeddedFeedJSONStoreUUIDs`, `testParsesAndDedupesStoreCandidates`, `testParsesStorePageNameAndGeo`, `testSimilarityScores`, `testNotFoundCooldownGate`, `testStoreUUIDExtraction` |

## Store & data safety

| Contract | Enforced by |
|---|---|
| New `Restaurant` stored properties are Optional — a non-optional addition silently wipes every user's store on decode. | CLAUDE.md hard rule 1; review gate |
| Sources never delete on failure; a *successful* complete-list sync may unstamp, guarded against parses under half the previous count. | `testSourceDroppingPlaceDoesNotDeleteIt`, `ListRemovalTests` |
| Merge is additive-only; `isHidden` survives re-syncs; negative markers are cleared by their successes. | `testMergesSamePlaceFromTwoSourcesWithin150m`, `testHiddenFlagSurvivesResync`, `testNegativeMarkersAreClearedByTheirSuccesses`, `testResolvedCidUpgradesStoredSearchURLButNeverExactOne` |
| Coordinate-less rows name-match only USER rows (source stamps / addedManually — not `michelinAward`); guide-only rows never absorb them. | `testNoCoordinateIncomingNeverMergesIntoMichelinRow`, `testNoCoordinateIncomingMergesIntoUserRowDespiteMichelinNamesake`, `testNoCoordinateIncomingMergesIntoUserRowThatAbsorbedGuideRow`, `testNoCoordinateIncomingMatchesByUniqueName`, `testSameNameFarApartStaysSeparate` |
| A store file that exists but fails to decode is set aside as `store.json.corrupt` — the next save must not overwrite the user's only copy. | `RestaurantStorePersistenceTests` (all three) |
| Saves are coalesced (3 s debounce / 20 s deadline) and strictly serialized — an older snapshot can never win the final write. | code-reviewed + verifier-confirmed (concurrency; no deterministic unit test — flagged debt) |

## Sync & network etiquette

| Contract | Enforced by |
|---|---|
| Michelin: weekly refresh; auto-download Wi-Fi/unmetered only; ETag 304 advances the clock without the body; failures back off hourly (`michelinLastRemoteAttempt` — a *download* clock, deliberately distinct from `SyncStatus.lastAttempt`); with guide data present a failed retry throws to SyncStatus instead of re-parsing local CSVs; forced refresh bypasses every gate. | parse layer: `MichelinDataSourceTests`, `CSVParserTests`; transport/gating: device + MAINTENANCE playbook (flagged debt) |
| Lists: weekly re-sync per enabled list, hourly failure backoff — EXCEPT lists that have never synced, which retry eagerly on every foreground (a list added offline must not sit empty for an hour). | code-reviewed (RootView is uncovered by units — UI-harness backlog) |
| Localizer: ≤40 fetches per visit, 0.4 s apart, cached forever; a genuine failure is negatively cached for the session, and cancellation never poisons that cache (gotcha #13). | parsing: `MichelinNameLocalizerTests`; fill loop (transport stubbed via `MichelinNameLocalizer.fetchName`): `testCancelledFillDoesNotPoisonTheNegativeCache`, `testGenuineFailureIsNegativelyCachedForTheSession` |
| Speculative fetches (card warm-up cid resolution) never run on cellular/Low Data Mode; explicit taps always may. | `GooglePlaceResolverTests` (classification); transport flag by review |
| Cid-resolution caching: a transient failure (shell page, network error, cancelled warm-up) never burns the session attempt and never persists; a definitive no-match persists a 30-day cooldown keyed to the search name it failed under; a newly localized name grants a fresh attempt; a resolved cid persists so later taps are exact. | `PlaceInfoFetcherPolicyTests` (transport stubbed via `PlaceInfoFetcher.resolveCid`); the stored-URL upgrade rule also `testResolvedCidUpgradesStoredSearchURLButNeverExactOne` |

## Settings & localization

| Contract | Enforced by |
|---|---|
| Michelin price/award filters persist across launches (empty = a real choice); `includeFormer` is session-scoped. | UI: `testMichelinFiltersPersistAcrossRelaunch`; unit test via injected `UserDefaults` suite — backlog |
| Page budgets are independent per tab; each mode remembers its own value. | `AppSettingsTests` |
| Every user-facing string outside a SwiftUI view literal uses `String(localized:)` with en/zh-Hant/ja entries in the catalog. | `LocalizationCatalogTests.testEveryKeyHasAllLanguages` |
