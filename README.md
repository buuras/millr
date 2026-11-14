# Millr

<img src="Resources/AppIcon.png" width="128" alt="Millr icon">

A Miller-columns file manager for macOS, written in Swift and AppKit. Folders open as
side-by-side columns; type to filter the focused column, and copy, move, rename, archive
and undo from the keyboard.

Inspired by [OneCommander](https://onecommander.com). Not affiliated with it.

The UI is available in English and Turkish. It follows the macOS language; choose another one in **View → Language**.

## Features

- Miller-columns browsing with a live filter in the focused column
- Dual pane, tabs, back/forward, recent and frequent folders
- Copy, move, duplicate, rename and trash as background jobs with progress, pause,
  cancel and undo/redo
- Browse zip/tar archives and disk images like folders; extract and compress
- Command palette
- Smart folders (Spotlight queries)
- Preview panel with Quick Look and file details
- Sidebar with places, volumes and cloud providers (iCloud Drive, File Provider folders)
  with sync badges
- Folder sizes, per-folder sorting, themes
- Shelf for collecting files to drop elsewhere

## Requirements

- macOS 14 or later
- Swift 5.9 toolchain (Xcode 15+ or the Command Line Tools)

## Build

```sh
./build.sh            # release build
./build.sh debug      # debug build
open "build/Millr.app"
```

The script runs `swift build`, assembles `build/Millr.app` and signs it ad hoc.
The app is not notarized; macOS may ask you to confirm the first launch.

## Tests

Both test modes create and delete files. Run them only on a disposable volume.

**Self-test:** runs copy/move/undo, archive, smart folder and palette checks against
a folder, and prints PASS/FAIL lines. The folder is **deleted** at start and end, so
pass a path that does not exist yet, ideally on a temporary disk image:

```sh
hdiutil create -size 1g -fs APFS -type SPARSE -volname OCSelf /tmp/ocself.sparseimage
hdiutil attach /tmp/ocself.sparseimage -nobrowse
"build/Millr.app/Contents/MacOS/Millr" --selftest /Volumes/OCSelf/t
hdiutil detach /Volumes/OCSelf
```

**Stress test:** `stress/run.sh` creates two temporary APFS sparse images (8 GB and 5 GB,
mounted at `/Volumes/OCStressA` and `/Volumes/OCStressB`), fills one with synthetic data
(`stress/gen.py`: a 50k-item folder, a 100k-file tree, deep nesting, Unicode names, large
files, a 20k-entry zip), runs the app with `--stress`, records leaks and memory, then
detaches and deletes the images. It backs up and restores the app's defaults.
Modes: `all` (default), `setup`, `test [--only name,name]`, `clean`. Output goes to
`stress/out/` (git-ignored). Make sure no volume of yours is named `OCStressA` or `OCStressB`.

## License

[MIT](LICENSE)
