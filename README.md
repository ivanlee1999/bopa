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
- [ ] **M2 — iPad app MVP:** notebook browser + PencilKit canvas; open/edit/save Notable
      notebooks locally; PKDrawing ↔ Notable stroke conversion
- [ ] **M3 — Sync engine:** WebDAV client (PROPFIND/GET/PUT/MKCOL), ETag + If-Match
      reconciliation, tombstones — interoperating with a live Notable instance
- [ ] **M4 — Polish:** pen/background mapping parity, images, conflict UX, PDF export

## Repo layout

```
docs/          protocol spec and design notes
NotableKit/    Swift package: format codec + sync engine (M1/M3)
App/           iPad app (M2+)
```

## License note

Ethran/notable is GPL-3.0; this project links none of its code — it independently implements the
wire format (facts/interfaces, documented in docs/) and can be licensed separately.
