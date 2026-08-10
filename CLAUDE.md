# Testing standard

All testing goes through `./scripts/test.sh` (tiers: `kit`, `app`, `quick`, `ui`, `full`).
Costs: `kit` ~1s (33 tests, no simulator) · `app` seconds (116 unit tests in the
simulator) · `ui` ~2.5 min (7 XCUITests).

**Do not run the UI tests after every change.** The rule:

- **While iterating:** run the tier matching what you touched — `kit` for
  `NotableKit/`, `app` for `App/Sources`.
- **Before every commit:** `./scripts/test.sh quick` (kit + app; well under a minute).
- **UI tests locally** only when the change touches interaction plumbing —
  `EditorView`, `CanvasContainerView`, gesture/eraser/rotation/scroll-lock
  behavior, or the UI tests themselves. For everything else, CI is the gate:
  every push and PR runs the full suite including `BopaUITests` on an iPad
  simulator (`.github/workflows/ci.yml`), and the PR isn't mergeable until green.

Correctness is preserved by *where* tests live, not by rerunning the slow ones:
new logic gets a unit test in `NotableKit/Tests` or `App/Tests` (both cheap
enough to run constantly). Add a UI test only when the behavior genuinely needs
touch synthesis — keep that suite small and interaction-focused.

**Visual changes** are covered by snapshot tests (swift-snapshot-testing) in the
fast tier — template rendering in `NotableKit/Tests`, stroke/ink rendering in
`App/Tests` — so "does it still look right" does not require the UI tier either.
Reference images live in `__Snapshots__/` next to the tests and are committed.
After an *intentional* visual change: `RECORD=1 ./scripts/test.sh quick`
re-records them; inspect the image diff before committing. A snapshot test that
fails on an unrelated change is a real regression, not noise — the tolerances
already absorb cross-machine antialiasing drift.

Known flake: a simulator run occasionally dies with "Early unexpected exit …
before establishing connection". That's the runner crashing before attaching,
not a product failure — rerun once before investigating.
