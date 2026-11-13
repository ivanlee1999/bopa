# Bopa 0.9.0 (build 11)

## Journal and topics

- Start in Today, create multiple independent notes each day, and browse other days.
- Assign reusable topics and browse every note linked to a topic.
- Sync journal dates and topic changes with Notable and the Obsidian companion through
  the separate `<notes database>_organization` CouchDB database.
- Keep ink and existing notebooks in their current format. Metadata remains on disk
  while offline, including topic removals and metadata for missing or trashed notebooks.
- Merge concurrent topic changes independently, retain captured dates, retry conflicts,
  and stop retired sync sessions after settings change.

Run the updated CouchDB provisioning script before using journal synchronization.
It creates the organization database with the same sync-account permissions.

## Validation and limits

The required quick suite covers 533 app tests and 385 kit XCTest cases, plus the kit
Swift Testing suite. Environment-dependent integration tests skip without their
servers. Before release preparation, all eleven journal tests passed against an
isolated live CouchDB, including convergence between two writers, offline restart,
removal and re-addition, conflict retry, strict validation, shared cross-client merge
vectors, and session retirement.

Physical iPad/Pencil and three-device production sync validation remain pending.
Existing ink/Pencil timing limitations described in the 0.8.2 release remain.

## Distribution

The signed iOS archive uses bundle identifier `dev.ivan.bopa` and Apple team
`357RJB33ZU`. An App Store Connect IPA is intended for Apple upload and TestFlight;
it cannot be installed directly from GitHub. Source ZIP/tar.gz archives contain
source code only. Release notes identify the actual upload and processing status.
