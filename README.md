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
- [ ] **M4b — Remaining polish:** native lined/grid templates, page delete/reorder,
      share as PDF, handwriting search/OCR, PDF import from iPad

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

## License note

Ethran/notable is GPL-3.0; this project links none of its code — it independently implements the
wire format (facts/interfaces, documented in docs/) and can be licensed separately.
