# DriveDex — notes for Claude

DriveDex is a free macOS app (Swift, no dependencies) that catalogs every drive / NAS share the user connects
(names, sizes, dates only — never file contents), lets them browse and search offline drives, checks whether
main drives are fully backed up, and syncs the catalog between their Macs. The owner is a Mac user (not a
developer, German keyboard) with several external drives, SSDs and two NAS backups that they swap between home
and office. Explain things in plain language, not developer terms.

## Repo & releases

- Repo: `marcialsommer/drivedex` (public). It was renamed from `drivedexloo`; GitHub redirects the old name.
  **Never create a repo called `drivedexloo`** — that would break the redirect older installs rely on.
- Share link for people: https://github.com/marcialsommer/drivedex/releases/latest
- **Every push to `main` builds and publishes a release** (`.github/workflows/build.yml` → `build.sh`) on a
  `macos-15-intel` runner (arm64 runners kept failing to start). The `latest` release is deleted and recreated
  with `DriveDex.dmg`, `DriveDex.zip` (used by the in-app updater) and `docs/DriveDex-Guide.pdf`.
- For docs-only changes add `[skip ci]` to the commit message so no build runs.
- **Bump `VERSION` in `build.sh` for every app change** (e.g. 2.1.5 → 2.1.6). `CFBundleVersion` is the
  GitHub run number. The release title must stay `DriveDex <version> (build <N>)` — the updater parses
  `build (\d+)` from it and compares with the installed build.
- No local Mac is available in cloud sessions: you can't compile here. Push, then check the build:
  - Runs: `curl -s https://api.github.com/repos/marcialsommer/drivedex/actions/runs?per_page=3`
  - Errors: `build.sh` re-emits swiftc errors as annotations, readable without auth via
    `.../commits/<sha>/check-runs` → `output.annotations_url`. (Job logs need auth.)
  - "The job was not acquired by Runner" = GitHub capacity problem, not our code; push an empty commit to retry.
- **Before telling the user a version is live, verify** the release is not a draft and that
  `https://github.com/marcialsommer/drivedex/releases/latest/download/DriveDex.dmg` returns 200.
  (A release was once silently created as a draft; the workflow now forces `--draft=false`.)
- Commits: author `Marcial Sommer <351895253+marcialsommer@users.noreply.github.com>` or the default Claude
  identity. **Never use the owner's personal email** in commits (history was rewritten once to remove it).

## Code map

| File | What |
|---|---|
| `Sources/main.swift` | AppDelegate: window (WKWebView), menus (Settings ⌘, · Find ⌘F · Help ⌘?), menu-bar status icon + health menu, page `confirm()` dialogs, notifications |
| `Sources/Scanner.swift` | Volume detection (DiskArbitration, IOKit SSD/HDD), mount/unmount observers, scanning (one at a time on a serial queue; `queueState()`), new-drive approval, reminders |
| `Sources/Catalog.swift` | SQLite wrapper + schema/migrations (`addColumn`), search, backup coverage (`recomputeCoverage`, sets, folder locations, exclusions, strict mode, history), space info, health, sync import/export |
| `Sources/Sync.swift` | Sharing via a folder (iCloud Drive default): per drive `<id>.entries.db`, `<id>.meta.json`, `<id>.history.json`, plus `prefs.json` |
| `Sources/Updater.swift` | In-app updates from the GitHub `latest` release (download zip, swap app, relaunch) |
| `Sources/Bridge.swift` | Actions the web UI calls (`window.webkit.messageHandlers.api.postMessage({action,args})`) |
| `Resources/index.html` | The entire UI (vanilla JS/CSS) |
| `tools/` | Dev helpers (see below) |

Key facts:
- Bundle id `app.drivedex.DriveDex`; catalog at `~/Library/Application Support/DriveDex/catalog.db`. Don't
  change either (users would lose their catalog/permissions). Add DB columns only via `addColumn` migrations.
- Backup matching = same normalized name (`nkey`: Unicode NFC + SMB stand-in characters undone) and same size,
  anywhere in the backup location; strict mode also requires mtime within 2.5 s. Locations in the same `grp`
  form a backup set (one backup). Each backup drive gives one location per main drive (whole drive or a folder). A backup can also be
  *partial* (`backups.source_path`): only that folder of the main drive is compared (`sourceScopeSQL`), with its own
  `cov_total_bytes`; set via folder right-click "This folder is backed up on…" (from the original) or "…is a copy of the one on…"
  (from the copy: `setCopyOf`, finds the same-named folder on the main drive), synced as `scopes` in meta.
- Backup percentages are **by data** (bytes: `cov_bytes`, `cov_one_bytes`, `cov_two_bytes`, per set `total_bytes` −
  `missing_bytes`), never 100% while a file is missing; file counts are shown alongside.
- Every scan (local, failed, or imported from another Mac) is written to `scan_log`; shown on the Info tab.
- Live scan progress: `drives.scan_started` / `scan_files` feed the activity bar (`drawActivity()` in index.html)
  and the menu-bar menu. Settings is a toggle (`toggleSettings()` returns to the previous view).
- Column view has an info panel (`drawInfoPane`, backend `folderInfo`: recursive file/folder counts, size,
  backup state) and a bottom path bar; the top breadcrumb is hidden in column mode.
- File views: Icons / List / Columns (`viewMode`, `drawIcons`, `drawList`, `drawColumns`). Folder backup dots come
  from `folderCoverage` (cached in `fcov`); ⇄ marks folders with links (`folderLinks(d,path)`).
- Back/Forward: `noteNav()` records places (mode, drive, path, tab) after each render; `goNav(±1)`; Go menu in main.swift.
- Undo: link changes go through `undoable(ids, fn, msg)` → `linksSnapshot` before, `linksRestore` on Undo (toast
  button, ⌘Z via Edit → Undo when no text field is focused). `removeLink` deletes one link. Use `undoable` for any
  new action that changes roles or backup links.
- Shoot mode (`Sources/Shoots.swift`, the "Shoots" tab of the sidebar: `shootsSide()`; tabs switch by `state.mode`): a shoot = name + main {key,path} + backups [{key,path}]
  + cards [{key,label,vol}], stored as JSON in table `shoots`, synced as `shoots.json` (newest per uuid wins).
  While a shoot is active on this Mac (`Settings activeShoot`), `Scanner.scan` calls `Shoots.claimCard` first: new local
  drives become cards only if the shoot has `autoAdd` and `Shoots.looksLikeCard` (camera folders); otherwise the normal
  new-drive prompt offers "Add to <shoot>" (bridge `approveCard`). (v2.6.2: the owner was surprised that every SD
  card was added silently while a test shoot was active.) Cards are always re-read.
  Memory cards (`VolumeInfo.isCard`: card-reader protocol/model words, camera maker/model words for cameras plugged in
  directly (≤1 TB), or camera folders on ≤1 TB drives; overridden by
  `Settings.notCardKeys`) are never catalogued as normal drives: `Scanner.scan` keeps them pending ("Add to shoot" /
  "Start a shoot…" / "Not now" = bridge `dismissDrive`, never the name-based ignore list) and sets `drives.is_card`
  (synced in meta; 1 = hidden from sidebar/overview, -1 = the user chose "Add to my drives" = bridge `notACard`; Settings →
  Memory cards lists hidden ones + `forgetCards`). Nothing may enter the drive list without the user asking.
  Card files counted: only `Shoots.mediaExts` (photos/RAW, video, audio) when `mediaOnly` (default true; the owner
  never copies THM/SCR/IDX/DB/XML/LRV/LRF); `Shoots.counts` is used by both the status and the deep check. `Shoots.status` compares card files (name+size) with
  each destination folder: live walk if connected, else catalog. Cards are hidden from the sidebar (`d.card`).
  DriveDex never copies files; the owner may later want copying/offload built in.
  Destinations are picked with `drivePicker` (searchable, connected first) or bridge `chooseFolder` (NSOpenPanel; maps
  the folder to a catalogued volume key + relative path, or to an internal-drive spec {local, mac, path} checked only
  on that Mac via `Shoots.localRoot`).
- Deep check (`Sources/DeepCheck.swift`, `Sources/XXH64.swift`): per card, reads every card file and each
  candidate copy (same name+size) in each connected destination with `F_NOCACHE`, compares XXH64; one check at a
  time on its own queue; result saved as `cards[i]["deep"]` (state verified/partial/problems/stopped, per-dest
  counts, up to 300 problems); valid while card bytes+files are unchanged (`deep_valid`). Live progress via bridge
  `deepState`. Stops on eject. `Tests/main.swift` checks XXH64 against official vectors in build.sh (build fails
  if wrong). Next idea: read Hedge/Silverstack MHL files to count their copies as verified.
- Card formatting / renaming (`Sources/CardTools.swift`, bridge `formatCard` / `renameCard`): the ONLY code that writes
  to a disk. `CardTools.target` requires: card of the shoot, not a destination, connected, removable/ejectable whole
  disk ≤ 2.2 TB with no other mounted volume. Format also re-checks `Shoots.status` (state safe; deep problems block;
  no deep check needs `quick`), then `diskutil eraseDisk ExFAT|MS-DOS FAT32 <name> MBRFormat /dev/diskN` (FAT32 ≤32 GB),
  records `cards[i]["formatted"]`, optional eject. Names ≤ 11 chars. Empty cards trigger no notice. The owner
  formats DJI action-cam cards here (fixed names like "CHRIS SD1"), Sony/drone cards in camera.
- Overview table is sortable (`hsort`, `homeSorted()`, saved in localStorage; default = sidebar order).
- Scans can be stopped/dequeued (`Scanner.stop/stopAll`, `ScanError.stopped`): previous catalog kept,
  logged as 'stopped', and automatic rescans skip that drive for 12 h. Home = `goHome()` (Overview item / title).
- Ejecting: `Scanner.watchEjects` registers a DiskArbitration unmount-approval callback; it marks the mount as
  `ejecting` (never objects) and waits up to 3 s for a running scan to let go. Anything that reads a drive (scan walk,
  `packageSize`, `Shoots.walkLive`) must check `isEjecting` regularly. The owner once got "couldn't be ejected because
  DriveDex is using it".
  Eject buttons (⏏ in the sidebar, drive header, right-click) call bridge `eject`: `letGo` first, then
  `NSWorkspace.unmountAndEjectDevice`. The owner wants DriveDex never to hold a drive.
- Ad-hoc signed (no Apple Developer ID): first install needs "Open Anyway"; in-app updates don't.
- Swift is compiled in Swift 5 mode by a newer compiler: main-actor rules are enforced for explicitly
  `@MainActor` types (use `MainActor.assumeIsolated` where needed).

## Testing without a Mac

- `node tools/ui-preview.js <outdir>` — runs `Resources/index.html` in Chromium with a fake backend (example
  drives covering most states) and saves screenshots; prints page errors. Extend its fake `postMessage`
  handler when adding new bridge actions.
- Validate tricky SQL with Python's sqlite3 against small sample tables before pushing.
- The Swift side can only be checked by the CI build; test the real behaviour with the user.

## Docs (keep in sync!)

When a change affects what users see, update in the same commit/build and tell the user:
- `README.md` (GitHub landing page; screenshots in `docs/images/`, taken with example drives).
- `docs/DriveDex-Guide.pdf` (attached to every release, opened by Help → DriveDex User Guide). Regenerate:
  ```
  node tools/guide-shots.js /tmp/guide-work
  python3 tools/make-guide.py /tmp/guide-work docs/DriveDex-Guide.pdf Resources/icon.png docs/images/gatekeeper.jpg
  ```
  The text lives in `tools/make-guide.py` (reportlab; symbols like ⌘ ⊘ need the DejaVu font; emoji such as
  📍 ⏰ ⌛ don't render — leave them out of the PDF text). Bump the version on its cover/footer.

## Things the user asked for / prefers

- Everything the user sets up must sync between their Macs (roles, backups, sets, folder locations,
  exclusions, reminders, types, order, notes, history, ignored drives, strict mode).
- Drive types are only HDD / SSD / NAS; roles only Main files / Backup / Not marked. Roles are a dropdown and
  every role change goes through `changeRole()` in index.html, which asks before removing backup links
  (the user once lost a setup by mis-clicking). Keep destructive changes behind a confirmation.
  Context-menu items ignore clicks within 350 ms of opening (a right-click release once triggered a
  rescan); toasts stay ≥5 s and while hovered.
- Feedback arrives as GitHub issues (Settings → Feedback); issues are public.
- The owner shares the app with others: keep the README and guide current and friendly.

## Ideas not done yet

- Apple Developer ID signing + notarization (removes "Open Anyway"; needs the owner's paid account + secrets).
- Optional parallel scanning of different physical drives (currently strictly one at a time, by design).
- A real end-to-end test of the updater swap and of 3+-drive backup sets on the owner's Macs.
