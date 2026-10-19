# Bopa 0.8.2 (build 10)

## Fixes

- Preserve an active paragraph when a remote update both deletes its old identity and
  adds or erases handwriting. Refresh paragraph tombstones while the draft safely
  defers the canvas reload, then save the draft under a new identity.
- Keep all undo/redo actions for one paragraph attached to its latest restored identity
  across multiple editing sessions and saved deletions. Earlier edits, moves and
  resizes no longer append duplicate replacement paragraphs.
- Keep drawing Options from opening an unwanted software keyboard. A drawing-only
  input view preserves the full page; real text editing retains its normal keyboard.

## Validation and limits

Regression-only CI reproduced draft text disappearing from disk after combined remote
updates and duplicate paragraphs after multi-session redo: three tests failed before
these fixes. Additional coverage checks saved deletion followed by undo/redo through
older edit, move and resize actions, repeated identity replacements, and neighboring
text. The Options baseline failed on both iPad and iPhone; fixed UI tests verify no
keyboard or lost canvas height, drawing/undo, and real text keyboard behavior.

CI runs app/model tests, iPad and iPhone UI tests, NotableKit, Mac Catalyst compilation,
and cross-repository sync-vector parity. Release metadata is verified by its own CI.
CouchDB-dependent app tests and external server/scenario kit tests self-skip without
their test environment; these skips are not passing integration tests. Screenshots
are reviewed for the tested simulator layouts, not every split-view or VoiceOver mode.
Hardware keyboard shortcuts retain their implementation but need physical-device checks.

The pre-existing final Apple Pencil pressure/save timing race remains unresolved and
requires physical-device validation. Completely ambiguous multiple edited/reordered
strokes sharing a creation timestamp still lack a general identity solution. The wire
exporter does not promise every PencilKit-only force/appearance field. Test rapid ink,
immediate navigation/backgrounding, undo and remote changes with a physical Pencil.
No speculative lifecycle timing or callback-counting change is included.

## Source-only distribution

After all test/build jobs pass, Actions creates source ZIP/tar.gz archives, BUILD-INFO.txt
with the exact tested commit, and SHA256SUMS. PR artifacts identify merge previews; main
artifacts identify the actual merged commit. Actions artifacts last 30 days; GitHub
Release source archives are source code only.

No signed app, IPA or TestFlight build is provided. CI disables signing. Installable
iOS builds require Xcode, an authorized Apple Developer team, signing certificate and
provisioning profile; Mac distribution additionally requires Developer ID signing and
notarization credentials. This workflow does not provision them.
