# Bopa 0.8.0 (build 7)

## Changes

- Recent notebooks in the shared library/sidebar, with search and a Command-K notebook switcher.
- Commit text before switching notebooks, leaving the editor or entering the background.
- Block page/notebook changes during an active tool gesture or text editing session.
- Reconcile sync immediately when switching between notebooks.
- Preserve the originating ink tool when filing strokes across the top seam.
- iPad and compact-width iPhone navigation/persistence coverage, rotation screenshots,
  and build-identity checks for iPad and Mac Catalyst.

## Pencil timing scope

The experimental wait-for-next-drawing-callback mechanism was removed before release.
An unchanged pen/eraser/lasso gesture may have no mutation callback, and callbacks do
not identify a particular completed stroke. Waiting or counting them could leave
navigation blocked or release protection for the wrong gesture.

This release retains the existing tool-down/tool-up lifecycle and save timing.
Tests verify that unchanged gestures release navigation, late drawing changes do
not release a different active gesture, and each gesture resets tool provenance.
They do **not** prove that final Apple Pencil pressure has arrived at tool-up.
Apple documents that final force updates can arrive after pencil-up:
[Introducing PencilKit (WWDC 2019)](https://developer.apple.com/videos/play/wwdc2019/221/).
The pre-existing final-pressure/save race remains an explicit device-validation
limitation, not a claimed fix in this release. Validate rapid strokes, immediate
page/notebook switching, app backgrounding, undo, and remote updates with a physical
Pencil before relying on it for pressure-perfect archival capture.

## Download and validation

CI runs NotableKit, iPad app/unit/UI tests, iPhone navigation UI tests, Mac Catalyst
compilation and cross-repository sync-vector parity. The source-package job runs
only after all five succeed. Its Actions artifact contains committed-source ZIP
and tar.gz archives, the exact tested commit in BUILD-INFO.txt, and SHA256SUMS.
PR artifacts contain the tested merge-preview commit; a main-branch run packages
the actual main commit. Artifact retention is 30 days.

CouchDB integration tests self-skip without a configured server; a green simulator
run is not evidence that these server-dependent tests passed. Simulator tests and
screenshots do not replace physical Apple Pencil pressure testing.

These are **source packages**, not signed installable apps or a published GitHub
Release. CI explicitly disables code signing. Building an installable iOS archive
requires Xcode, an authorized Apple Developer team, a signing certificate and an
appropriate provisioning profile. Mac distribution additionally needs Developer ID
signing/notarization credentials. See scripts/archive.sh; credentials and signing
configuration are not provisioned by this source-package workflow.
