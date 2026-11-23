<p align="center">
  <img src="docs/images/icon.png" width="128" alt="DriveDex icon">
</p>

<h1 align="center">DriveDex</h1>

<p align="center">
  <b>Know what's on every drive, even the ones in a drawer, and whether it's backed up.</b><br>
  A small, free Mac app for people who juggle external drives, SSDs and NAS shares.
</p>

<p align="center">
  <a href="https://github.com/marcialsommer/drivedex/releases/latest/download/DriveDex.dmg"><b>⬇︎ Download DriveDex for Mac</b></a>
  &nbsp;·&nbsp;
  <a href="docs/DriveDex-Guide.pdf"><b>📖 User guide (PDF)</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/marcialsommer/drivedex/releases/latest">Release notes</a>
</p>

<p align="center">
  <img src="docs/images/hero.png" alt="DriveDex: drives grouped with their backups, and a Finder-style column view" width="900">
</p>

## What it does

- **Catalogs every drive automatically.** Plug in a drive or connect a NAS share and DriveDex records what's on it: file and folder names, sizes and dates. It never reads file contents. Known drives are updated whenever you connect them.
- **Browse and search drives that aren't connected.** Finder-style icon, list and column views with back and forward buttons, and search across all your drives at once. Identical files show as one result ("on 3 drives"), and you can filter by videos, photos, projects and more.
- **Shows whether everything is backed up.** Mark which drives hold your originals and where their backups are: whole drives, a folder on a NAS, or a backup split over several drives. DriveDex checks file by file and shows what's on 2+ backups, on 1, or on none, with the exact list of what's missing. Changed a link by mistake? Every change can be undone.
- **Tells you when something needs attention.** A "Needs attention" home screen and a menu-bar icon that turns orange or red. There's also an optional reminder when a backup drive hasn't been connected for a while, handy if you swap backups between home and the office.
- **Shoot mode for productions.** Plug in memory cards and see, card by card, whether everything is on your main drive and on every backup, and when a card is safe to format.
- **Remembers where drives live.** A location note ("office, top drawer") and which Mac last saw each drive, shown in the drive list and in search results.
- **Works across your Macs.** Share the catalog through iCloud Drive, Google Drive or Dropbox, so every Mac sees every drive.
- **Updates itself.** One click installs new versions.

<table>
  <tr>
    <td width="50%"><img src="docs/images/home.png" alt="Needs attention"><br><sub><b>Needs attention:</b> files without a backup, incomplete or overdue backups.</sub></td>
    <td width="50%"><img src="docs/images/backups.png" alt="Backup status"><br><sub><b>Backup status per drive:</b> each backup's completeness, last time in sync, history.</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/images/search.png" alt="Search"><br><sub><b>Search every drive at once</b>, including disconnected ones, with copies grouped together.</sub></td>
  </tr>
</table>

<sub>Screenshots use example drives.</sub>

## Install

1. [Download **DriveDex.dmg**](https://github.com/marcialsommer/drivedex/releases/latest/download/DriveDex.dmg), open it and drag **DriveDex** into **Applications**.
2. Open DriveDex. macOS will say it can't verify the app. Click **Done** (not Move to Trash).
3. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to DriveDex.
4. When asked, allow access to removable and network volumes.

You only do steps 2–3 once. DriveDex isn't signed with a paid Apple developer certificate, which is why macOS asks. Updates installed from inside the app don't need it again.

Requires **macOS 13 Ventura or newer** (Apple Silicon or Intel). The [user guide](docs/DriveDex-Guide.pdf) explains everything step by step.

## Privacy

- DriveDex only stores **names, sizes and dates** of files and folders. It never opens or uploads your files.
- The catalog stays **on your Mac**. If you turn on sharing between Macs, it's also stored in **your own** iCloud Drive or sync folder.
- Nothing is sent to anyone else. The only network requests are to GitHub, to check for and download updates.
- DriveDex never changes anything on your drives.

## Feedback

Found a problem or have an idea? Use **Settings → Feedback** in the app, or [open an issue](https://github.com/marcialsommer/drivedex/issues/new). Issues are public, so please leave out private file names.

DriveDex is a personal project, provided as is. It's a great help for finding things and spotting gaps in your backups, but don't make it your only check.

---

<details>
<summary><b>For developers</b></summary>

Plain Swift with no dependencies: an AppKit shell with a WKWebView interface and a SQLite catalog.

| Path | What |
|---|---|
| `Sources/main.swift` | App, window, menus, menu-bar icon |
| `Sources/Scanner.swift` | Drive detection, scanning, reminders |
| `Sources/Catalog.swift` | SQLite catalog, search, backup coverage |
| `Sources/Sync.swift` | Sharing the catalog between Macs |
| `Sources/Updater.swift` | In-app updates from GitHub releases |
| `Sources/Bridge.swift` | Actions the interface calls |
| `Resources/index.html` | The interface |

Every push to `main` is built by GitHub Actions (`.github/workflows/build.yml` → `build.sh`) and published as the `latest` release (`DriveDex.dmg` plus `DriveDex.zip` for the updater). To build locally on a Mac with the Xcode command line tools: `./build.sh`.

</details>
