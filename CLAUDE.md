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
  form a backup set (one backup). Each backup drive gives one location per main drive (whole drive or a folder).
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
- Drive types are only HDD / SSD / NAS; roles only Main files / Backup (click again to clear).
- Feedback arrives as GitHub issues (Settings → Feedback); issues are public.
- The owner shares the app with others: keep the README and guide current and friendly.

## Ideas not done yet

- Apple Developer ID signing + notarization (removes "Open Anyway"; needs the owner's paid account + secrets).
- Optional parallel scanning of different physical drives (currently strictly one at a time, by design).
- A real end-to-end test of the updater swap and of 3+-drive backup sets on the owner's Macs.
