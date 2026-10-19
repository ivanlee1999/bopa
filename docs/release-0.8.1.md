# Bopa 0.8.1 (build 8)

## Changes

- Calmer writing header with one forward/add-page control, more room for the notebook
  title, visible Options and a separate page-control row at accessibility text sizes.
- Compact toolbar keeps writing, eraser, selection, text, undo, redo and ink within
  reach. Return to the previous writing tool in one tap; tap the selected tool for
  settings. Large-text settings use a full-width sheet with a pinned close button.
- Notebook switcher uses a quiet monochrome list and clearly marks the current notebook.
- Preserve later stroke snapshots when their control-point count has changed instead
  of reusing an earlier same-identity saved path. Coverage includes repeated saves,
  failed-save retry and stable stroke IDs.
- Fix an iPad Options-menu freeze: undo availability checkpoint notifications were
  republishing unchanged state and repeatedly rebuilding the native menu. Refresh now
  guards reentry and publishes only changes, with undo/redo and manager-switch tests.

## Validation and limits

CI runs NotableKit, iPad app/unit/UI tests, iPhone navigation UI tests, Mac Catalyst
compilation and cross-repository sync-vector parity. UI coverage includes switching
with persisted ink/text, page creation, undo isolation, rotation, background relaunch,
visible compact controls, Options and accessibility-size layouts. Simulator screenshots
are reviewed; this does not establish every split-view size or VoiceOver behavior.

The preceding code revision passed 499 app tests (9 CouchDB-dependent skips), 374 kit
tests (12 server/scenario-dependent skips), 16 iPad UI tests and 7 iPhone UI tests.
Release version metadata is checked by the release revision's separate CI run. A green
run does not mean the skipped CouchDB/interop/scenario integration tests passed.

Stroke snapshot reuse now checks point count, but does not detect same-count changes
to pressure or geometry. The existing tool-down/tool-up lifecycle and save timing are
unchanged. Final Apple Pencil force updates can arrive after pencil-up; the pre-existing
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
