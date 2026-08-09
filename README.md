# bopa — BOOX ↔ iPad handwriting notes over WebDAV

Handwritten notes editable on both a BOOX e-ink tablet and an iPad, synced through any generic
WebDAV server. No proprietary cloud, no manual import taps.

## How

- **BOOX side:** stock [Ethran/notable](https://github.com/Ethran/notable) (GPL-3.0) — an
  open-source note app built on the Onyx raw-pen SDK (near-native writing latency) with built-in
  WebDAV sync (experimental, since v0.2.5).
- **iPad side (this repo):** a native SwiftUI + PencilKit app that speaks Notable's WebDAV sync
  protocol directly — same folder layout, same JSON, same stroke binary format. See
  [docs/notable-sync-protocol.md](docs/notable-sync-protocol.md).

Because both apps read and write the same on-server format, a note started on either device is
fully editable, stroke by stroke, on the other — pressure and tilt included.

## Status / roadmap

- [x] Research interop options (BOOX `.note` is a dead end over WebDAV; PDF loop flattens ink)
- [x] Reverse-document Notable's sync protocol (pinned at v0.2.6, `eb3a4c1`)
- [x] **M0 (hardware validation):** Notable APK on the BOOX Tab 10 C — verify raw-pen latency and
      WebDAV sync against the target server
- [x] **M1 — NotableKit (Swift package):** codec for the SB stroke binary (polyline, LZ4 block,
      pressure/tilt/dt channels), manifest/page/folders JSON, round-trip test suite
- [x] **M2 — iPad app MVP:** notebook browser + PencilKit canvas; open/edit/save Notable
      notebooks locally; PKDrawing ↔ Notable stroke conversion
- [x] **M3 — Sync engine:** WebDAV client (PROPFIND/GET/PUT/MKCOL), ETag + If-Match
      reconciliation, tombstones; verified two-device convergence against a real WebDAV
      server (rclone)
- [ ] **M3.5 — Live interop:** sync with the actual BOOX Tab 10 C running Notable against
      Ivan's WebDAV server; verify a note edited on both devices round-trips
- [x] **M4a — App parity batch** (3 parallel agents): folder hierarchy + notebook
      rename/move/delete (with offline tombstones), page images rendered under the ink,
      undo/redo, per-page scroll persistence, PDF page backgrounds, auto-sync on
      launch/foreground with status capsule
- [ ] **M4b — Remaining polish:** native lined/grid templates (NotableKit: import, storage and
      rendering done — see [Templates](#templates); App-side picker UI still open), page
      delete/reorder, share as PDF, handwriting search/OCR, PDF import from iPad

## Running it on a real iPad

Simulator: `cd App && xcodegen generate && open Bopa.xcodeproj`, pick an iPad, Run.

Device (free personal team): set your team under Signing & Capabilities, plug in the
iPad, Run. Note the build expires after 7 days and must be re-installed.

TestFlight (needs a paid Apple Developer Program membership):

```bash
./scripts/archive.sh <YOUR_TEAM_ID>
```

produces a signed `.ipa` in `build/export`. Create the app record in App Store Connect
(bundle id `dev.ivan.bopa`), upload with Transporter or Xcode Organizer, then add
yourself as an internal tester. The app icon, privacy manifest (UserDefaults, reason
CA92.1) and export-compliance declaration are already in place.

## Repo layout

```
docs/          protocol spec and design notes
scripts/       archive.sh (TestFlight builds), webdav-check.sh (server diagnosis)
tools/         dbverify / dbimport / dbexport / icongen
NotableKit/    Swift package: format codec + sync engine (M1/M3)
App/           iPad app (M2+)
```

## Templates

A template is one page you write on: a built-in grid, an imported image, or one page of an
imported PDF — a planner downloaded from [onplanners.com](https://onplanners.com/), say. Importing
a multi-page PDF gives you one template per page to choose from; the file itself is stored once.

```swift
let library = TemplateLibrary(notableDirectory: appSupportDirectory)

// Import a downloaded planner -> one single-page template per PDF page.
let pages = try library.importTemplates(from: downloadedPDF)
let daily = pages[2]

// Use it: background fields for a page, and for the notebook's new-page default.
let plan = TemplateApplication.plan(pageCount: 30, from: daily)
// plan.pages[0]        -> background "pdfs/Daily-Planner.pdf", backgroundType "pdf2"
// plan.notebookDefaults -> same, for manifest.json
// plan.assets          -> files to PUT under notebooks/<id>/backgrounds/

// Draw it behind the ink, or in a picker.
let renderer = TemplateRenderer(store: library.store)
let backdrop = try renderer.image(for: daily, pageWidth: 1404, viewport: visibleRect, scale: 2)
let preview = try renderer.thumbnail(for: daily, size: CGSize(width: 150, height: 275))
```

Templates written this way are the form Notable's sync downloader understands — with one upstream
caveat about custom backgrounds on the BOOX side, see
[§7 of the protocol spec](docs/notable-sync-protocol.md#custom-backgrounds-do-not-round-trip-in-v026).

## License note

Ethran/notable is GPL-3.0; this project links none of its code — it independently implements the
wire format (facts/interfaces, documented in docs/) and can be licensed separately.
