# DriveDex

A small Mac app that keeps a catalog of what's on all your drives. Plug in a drive or connect a NAS share, and DriveDex catalogs it automatically. You can then browse and search every drive, including ones sitting in a drawer.

- **Automatic:** a drive is catalogued as soon as it mounts. A drive you plug in is rescanned if its last scan is more than an hour old. A NAS share that stays connected is rescanned every 12 hours. You can change both in Settings.
- **Light:** it records only names, sizes and dates. It never reads file contents. Junk folders (`.Spotlight-V100`, Synology `@eaDir`, `#recycle` and so on) are skipped. Final Cut libraries, Photos libraries and apps are listed as single items.
- **Search everything:** searches across all drives as you type, shows how many matches are on each drive, and jumps to the folder when you click a result.
- **Browse** any drive's folders with sizes, dates and item counts. **Show in Finder** works when the drive is connected.
- **Name and note** each drive, for example "Blue LaCie, office drawer".
- Runs quietly in the menu bar and starts at login. If a drive is unplugged mid-scan, its previous catalog is kept.

## Install

1. Download **DriveDex.dmg** from the [latest release](../../releases/latest).
2. Open it and drag **DriveDex** onto **Applications**.
3. Open DriveDex from Applications. The first time, macOS says it can't verify the app, because it isn't signed with a paid Apple developer certificate.
   Click **Done** (or **OK**), then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to DriveDex. You only do this once.
4. When macOS asks to let DriveDex access files on a removable or network volume, click **Allow**.

After that, DriveDex lives in your menu bar (drive icon). To open the window, click the menu bar icon or open the app again.

## Building

GitHub Actions builds the app on every push to `main` (`.github/workflows/build.yml`) and publishes `DriveDex.dmg` as the `latest` release. To build on a Mac yourself, install the Xcode command line tools and run `./build.sh`.

The code is plain Swift with no dependencies:
- `Sources/Scanner.swift`: drive detection and scanning
- `Sources/Catalog.swift`: SQLite catalog and search
- `Sources/Bridge.swift`: actions the window calls
- `Sources/main.swift`: app, window and menu bar
- `Resources/index.html`: the interface

The catalog is stored in `~/Library/Application Support/DriveDex/catalog.db`.
