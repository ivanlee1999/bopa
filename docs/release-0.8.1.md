# Bopa 0.8.1 (build 9)

## Changes

- Calmer writing header with one forward/add-page control, more room for the notebook
  title, visible Options and a separate page-control row at accessibility text sizes.
- Compact toolbar keeps writing, eraser, selection, text, undo, redo and ink within
  reach. Return to the previous writing tool in one tap; tap the selected tool for
  settings. Large-text settings use a full-width sheet with a pinned close button.
- Notebook switcher uses a quiet monochrome list and clearly marks the current notebook.
- Preserve changed stroke snapshots, including saved lasso undo, restored erasures and
  same-count geometry/width/ink changes. Content matching preserves untouched imported
  wire data and reserves unchanged timestamp siblings before edits claim their identities.
- Keep active typing on its originating page during remote deletion, then recover text
  and handwriting into a separate notebook. Explicit local deletion discards the draft;
  late finish/undo callbacks cannot write it onto another page. Recovery retries preserve
  deletions without resurrecting the removed source.
- Keep whole-paragraph undo when finishing text through a tool change or navigation.
  Undo/redo follows fresh block IDs across saved deletions and remote tombstones.
- Fix an iPad Options-menu freeze: undo availability checkpoint notifications were
  republishing unchanged state and repeatedly rebuilding the native menu. Refresh now
  guards reentry and publishes only changes, with undo/redo and manager-switch tests.

## Validation and limits

CI runs NotableKit, iPad app/unit/UI tests, iPhone navigation UI tests, Mac Catalyst
compilation and cross-repository sync-vector parity. UI coverage includes switching
with persisted ink/text, page creation, undo isolation, rotation, background relaunch,
visible compact controls, Options and accessibility-size layouts. Simulator screenshots
are reviewed; this does not establish every split-view size or VoiceOver behavior.

The regression-only baseline reproduced 17 failing data-safety tests before the fixes,
including text persisted onto an unrelated landing page and saved undo retaining moved
ink coordinates. Release version metadata is checked by the release revision's own CI.
CouchDB-dependent app tests and server/scenario-dependent kit tests self-skip without
their external test environment. A green run does not mean those skipped tests passed.

Content matching detects saved geometry/width changes without assuming when PencilKit
has finished a stroke. Completely ambiguous multiple edited/reordered strokes sharing
a creation timestamp still lack a general identity solution. The wire exporter does
not promise to retain every PencilKit-only force/appearance field. The existing
tool-down/tool-up lifecycle and save timing are unchanged. Final Apple Pencil force
updates can arrive after pencil-up; the pre-existing
final-pressure/save race remains unresolved and requires physical-device validation.
See [Introducing PencilKit (WWDC 2019)](https://developer.apple.com/videos/play/wwdc2019/221/).
Test rapid strokes, immediate page/notebook changes, backgrounding, undo and remote
updates with a physical Pencil before relying on pressure-perfect archival capture.
No speculative callback-counting or delayed-save mechanism is included.

## Source-only distribution

The Actions source-package job runs only after all five test/build jobs succeed. It
produces committed-source ZIP and tar.gz archives, BUILD-INFO.txt identifying the exact
tested commit, and SHA256SUMS. PR artifacts identify a merge-preview commit; main runs
identify the actual merged commit. Artifacts are retained for 30 days. GitHub Release
source archives are also source code only.

No signed app, IPA or TestFlight build is provided. CI disables code signing. An
installable iOS archive requires Xcode, an authorized Apple Developer team, signing
certificate and provisioning profile. Mac distribution additionally requires Developer
ID signing/notarization credentials. The source workflow does not provision these.
