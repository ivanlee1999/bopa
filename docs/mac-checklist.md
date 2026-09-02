# The Mac build: what to check by hand

CI builds the Catalyst app on every push (`.github/workflows/ci.yml`, job "App (Mac
Catalyst)") and that is the only automated gate it has: the unit tests run on an iPad
simulator, because their snapshots are recorded at iPad metrics, and there are no Mac UI
tests. So the things below are the ones only a person at a Mac can answer. Run through them
before a release that touches the editor, the window, or sync.

Build it with `./scripts/test.sh mac` (compile only) or from Xcode with the
*My Mac (Mac Catalyst)* destination.

1. **The window.** Opens no smaller than 900×620 and cannot be shrunk below it. One title bar
   with the traffic lights, and *no* system toolbar above the app's own top bar.
2. **Trackpad draws.** A new notebook, the pen tool, a drag on the trackpad leaves ink. The
   "Finger" setting does not exist on the Mac and must not be needed for this.
3. **Wheel scroll.** The page scrolls with the wheel and stops at the bottom. It does **not**
   append a page or turn one — those are ⌘] / ⌘[ / ⌘⇧N here, and the buttons in the top bar.
4. **Keyboard page turns.** ⌘] to the next page (and a new one from the last), ⌘[ back,
   ⌘⇧N a new page after this one.
5. **A PDF-backed page renders** its background, and a notebook made on the iPad opens with
   the same paper.
6. **A CouchDB sync completes.** This is what proves `com.apple.security.network.client` in
   `App/Bopa.entitlements` is in the signed app: without it every request fails and the app
   merely looks as though it never syncs. Settings › Sync › the server, then a page edited
   here appears on the other device and vice versa.
7. **Show Notebooks in Finder** (Settings) opens the container's `notebooks` folder.
8. **Apple Pencil settings are absent** from Settings; the Pages, Canvas and Paper sections
   are present.
