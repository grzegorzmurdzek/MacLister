# MacLister

A lister-based file manager for macOS in the spirit of **Directory Opus Magellan**: double-click the empty
desktop and a file lister opens right where you clicked. Native Swift (AppKit + SwiftUI), runs as a
menu-bar agent, no Dock icon.

**Language:** English · [Polski](README.pl.md)

## Highlights

- **Desktop double-click opens a lister** at the cursor. Any number of listers at once.
- **Source / destination listers** with Copy (F5), Move (F6), Extract, Compare, Swap.
- **Drag and drop** between listers and to/from Finder (Finder rules: same volume moves, ⌥ copies, ⌘ moves).
- **Configurable button bar**, **filetype actions** (what a double-click does), **bookmarks**, **saved layouts**.
- Select by pattern, filter, folder sizes, info panel, rename, duplicate, Quick Look on Space, archive extraction
  (zip, tar.\*, 7z, rar, gz, bz2 …).
- **Right-click the title bar** for lister commands (duplicate, source/destination, close all …).

## Requirements

macOS 13 Ventura or later. Apple Silicon or Intel (universal build; the Intel half has not been run on real
Intel hardware).

## Install

1. Download `MacLister-<version>-macos.zip` from the **Releases** page of this repository. Optionally verify it
   against the `.sha256` file: `shasum -a 256 -c MacLister-<version>-macos.zip.sha256`.
2. Unzip it and drag **MacLister.app** into `/Applications`.
3. **First launch.** The app is ad-hoc signed, not notarized, so Gatekeeper blocks it at first:
   - Control-click the app → **Open** → **Open**, or
   - System Settings → Privacy & Security → **Open Anyway** (macOS 15 and later), or
   - run `xattr -dr com.apple.quarantine /Applications/MacLister.app` once.
4. **Grant two permissions** in System Settings → Privacy & Security:
   - **Accessibility** – to recognise what is under the cursor (empty desktop vs. icon, window, Dock).
   - **Input Monitoring** – macOS requires it for the passive event tap that sees double-clicks.

   Switch both on for MacLister, then **quit and start the app again** (menu-bar icon → *Quit MacLister*).
5. Click the menu-bar icon. The first line should read **Desktop double-click: active**.
6. *Recommended:* turn off the system's "reveal desktop" feature, otherwise the first click of a double-click
   slides all windows aside and the new lister can end up partly off-screen.
   System Settings → Desktop & Dock → **Click wallpaper to reveal desktop** → *Only in Stage Manager*, or:

   ```bash
   defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
   ```

7. *Optional:* start at login via System Settings → General → Login Items → **+** → MacLister.

**Uninstall:** quit from the menu-bar icon, delete the app, remove `~/Library/Application Support/MacLister`,
run `defaults delete com.example.MacLister`, and remove MacLister from the two Privacy lists.

## Using MacLister

### Opening a lister

- **Double-click an empty spot on the desktop.** Nothing happens on icons, windows, the menu bar or the Dock,
  and clicks with ⌘/⇧/⌥/⌃ held are ignored.
- Or use the menu-bar icon → **New Lister**.
- By default the window's top-left corner sits on the click; menu-bar icon → **Center Lister on Cursor**
  centres it instead. A lister opens on your home folder (see *startDirectory* below).

### Anatomy of a lister

- **Path bar:** *Back*, *Parent*, the **Go** menu (places, volumes, bookmarks, recent folders), an editable
  path field (type a path, `~` works, press Return) and the **SRC** / **DST** badges.
- **File list:** icon, name, size, modified date. Click a header to sort; folders always come first.
  Double-click or Return opens a file or enters a folder.
- **Button bar** at the bottom (see *Configuration*) and a status line: item count, selection size, filter,
  progress and errors.
- The window subtitle shows the item count and the lister's role (SOURCE / DESTINATION).

### Source and destination

Mark one lister as **SRC** and another as **DST** with the badges in the path bar (click again to clear).
Then:

| Action | What it does |
|---|---|
| **Copy** (F5) | copies the selection of the source lister into the destination lister's folder |
| **Move** (F6) | moves it there |
| **Extract** (⌘E) | unpacks selected archives into a new sub-folder of the destination folder |
| **Compare** | selects, in both listers, items that are missing on the other side or differ (size / newer) |
| **Swap** | exchanges the roles |
| **Open in Destination** | context menu: shows the selected folder in the destination lister |

If no lister is marked SRC, the lister whose button you pressed is the source. When a name already exists you
are asked: **Replace** (the old item goes to the Trash), **Keep Both** ("name 2.ext"), **Skip** or **Cancel**.

### Keyboard

| Key | Action |
|---|---|
| Space | Quick Look (arrows move through files, Space closes) |
| Return, ⌘↓ | open file / enter folder |
| Backspace, ⌘↑ | parent folder |
| ⌘⌫ | move selection to the Trash |
| F2 | rename |
| F5 / F6 | copy / move to the destination lister |
| ⌘E | extract archives |
| ⌘I | info (size, dates, permissions, owner) |
| ⌘D | duplicate the selected files (`name copy.ext`) |
| ⌥⌘D | **duplicate this lister** (same folder, size, sort, filter) |
| ⌘F | filter by pattern |
| `+` / `-` / `*` | select by pattern / deselect by pattern / invert selection |
| ⌘A | select all |
| ⌘B | bookmark this folder |
| ⌘⇧. | show or hide hidden files |
| ⌘⇧L | bring all listers to the front |
| ⌘W | close the lister |

On many laptops F-keys need **fn**.

### Menus

- **Right-click the file list** – commands for the item(s) under the cursor (Open, Quick Look, Extract,
  Copy/Move to destination, Rename, Info, Duplicate, Reveal in Finder, Copy Path, Move to Trash), or for the
  folder when you click empty space (Select by Pattern, Filter, Calculate Folder Sizes, Compare, New Folder …).
- **Right-click the title bar** (or Control-click) – lister commands: **Duplicate Lister**, New Lister, Set as
  Source / Destination, Swap, Parent, Back, Refresh, Hidden files, Filter, Bookmarks, Recent Folders,
  Terminal Here, Bring All to Front, Close, Close All, Save/Restore Layout.
- **Menu-bar icon** – list of all open listers (click to bring one to the front; roles are shown as
  \[SRC\] / \[DST\]), Bring All to Front, Close All, *Duplicate Frontmost Lister*, *Terminal App*, layouts,
  *Edit Filetypes…*, *Edit Buttons…*, *Reload Buttons*, *Reset Buttons to Defaults*, permission status.

### Selecting, filtering, sizes

- **Select by pattern** (`+`): wildcards such as `*.jpg`, `IMG_??.png`; several patterns separated by spaces;
  text without wildcards matches names containing it. `-` deselects, `*` inverts.
- **Filter** (⌘F): shows only files matching the pattern (folders always stay). An empty pattern clears it.
- **Sizes**: calculates the recursive size of the selected folders (or all folders) into the Size column.

### Bookmarks and history

The **Go** menu has *Places* (Home, Desktop, Documents, Downloads, Applications, Root, mounted volumes),
*Bookmarks* (add the current folder, remove) and *Recent*. Bookmarks live in `bookmarks.json`.

### Filetypes: what a double-click does

`filetypes.json` (menu-bar icon → **Edit Filetypes…**) maps extensions to actions: `open` (system default),
`extract`, `quicklook`, `app` (bundle identifier or path of an application) and `shell` (the file is in
`$LISTER_SELECTION`). By default archives are **extracted** instead of opened. Example:

```json
[
  { "extensions": ["zip", "tar.gz", "7z", "rar"], "action": "extract" },
  { "extensions": ["md", "txt"], "action": "app", "app": "com.apple.TextEdit" },
  { "extensions": ["png", "jpg"], "action": "quicklook" }
]
```

The file replaces the defaults; changes are picked up immediately.

### Layouts

Menu-bar icon → **Save Layout** remembers every open lister (folder, position, size, role, sort, hidden files,
filter); **Restore Layout** reopens them. To restore automatically at launch:

```bash
defaults write com.example.MacLister restoreLayoutAtLaunch -bool true
```

## Configuration

Files in `~/Library/Application Support/MacLister/`:

| File | Purpose |
|---|---|
| `buttons.json` | bottom button bar |
| `filetypes.json` | double-click actions |
| `bookmarks.json` | bookmarked folders |
| `layout.json` | saved layout |

### Buttons

Menu-bar icon → **Edit Buttons…**, then **Reload Buttons** (all open listers update). **Reset Buttons to
Defaults** rewrites the file (use it after an update to get new default buttons).

```json
[
  { "title": "New Folder", "symbol": "folder.badge.plus", "action": "newFolder" },
  { "title": "Copy", "symbol": "doc.on.doc", "action": "copy", "help": "Copy to destination (F5)" },
  { "title": "Code", "symbol": "chevron.left.forwardslash.chevron.right",
    "action": "shell", "command": "open -a 'Visual Studio Code' \"$LISTER_DIR\"" }
]
```

`symbol` is an SF Symbols name (optional), `help` the tooltip, `requiresSelection` (true/false) overrides when a
button is enabled. **Actions:** `newFolder terminalHere delete parent back refresh revealInFinder open newLister
toggleHidden copy move setSource setDestination swapSourceDestination extract bringAllToFront duplicateLister
duplicateFile selectPattern deselectPattern selectAll selectNone invertSelection filter clearFilter calcSizes
compare info showInDestination destinationHere addBookmark shell`.
`shell` runs `command` with `/bin/zsh` in the current folder; `$LISTER_DIR` is that folder and
`$LISTER_SELECTION` the selected paths, one per line.

### Hidden settings

Set with `defaults write com.example.MacLister <key> <value>`:

| Key | Default | Meaning |
|---|---|---|
| `centerOnCursor` | false | centre new listers on the click instead of anchoring the corner |
| `showStatusItem` | true | show the menu-bar icon (if you hide it, quit via Activity Monitor) |
| `startDirectory` | `~` | folder a desktop double-click opens |
| `terminalBundleID` | `com.apple.Terminal` | terminal used by *Terminal Here* (also: menu-bar icon → *Terminal App*) |
| `restoreLayoutAtLaunch` | false | reopen the saved layout at start |
| `debugHitTest` | false | log every click decision to `~/Library/Logs/MacLister.log` |

## Troubleshooting

- **Nothing happens on a double-click.** Open the menu-bar icon: if it says *Waiting for Accessibility
  permission…*, grant both permissions (step 4) and restart the app. If permissions look right but are
  ignored (for example after reinstalling), reset them and grant again:

  ```bash
  tccutil reset All com.example.MacLister
  ```

- **A lister opens on an icon, or not on empty space.** Turn on `debugHitTest` and look at
  `~/Library/Logs/MacLister.log` – each double-click logs what was under the cursor.
- **Windows slide away and the lister is half off-screen.** Disable *Click wallpaper to reveal desktop*
  (install step 6).
- **"Terminal Here" opens the wrong app.** Menu-bar icon → *Terminal App*.
- **New buttons are missing after an update.** Menu-bar icon → *Reset Buttons to Defaults*.
- **Gatekeeper says the app is damaged or cannot be opened.** Install step 3 (`xattr -dr com.apple.quarantine`).

## Build from source

Requires Xcode or the Command Line Tools (Swift 5.9+).

```bash
./build.sh                       # build/MacLister.app for this Mac
./build.sh release --universal   # arm64 + x86_64
./package.sh                     # universal build zipped to dist/ with a SHA-256 file
```

Built-in self-tests drive real listers through roles, copy/move, extraction, menus, filters and more, and write
PASS/FAIL lines to `~/Library/Logs/MacLister.log`:

```bash
open build/MacLister.app --args --selftest
open build/MacLister.app --args --selftest-features
```

`MacLister --open [folder]` opens a lister at launch.

Layout: `Sources/MacLister/` – `DesktopDoubleClickMonitor` (event tap), `DesktopHitTest` (is this empty desktop?),
`ListerWindowController` / `ListerManager` (windows, roles, layouts), `ListerViewController` (+ `Features`)
(file table and actions), `Bars` (SwiftUI path and button bars), `FileTransfer`, `ArchiveExtractor`, `Stores`
(bookmarks, history, filetypes, layouts).

## Privacy and security

- To spot double-clicks MacLister reads mouse-button events system-wide through a **listen-only** event tap: it
  cannot change or block your input, and it ignores keystrokes. macOS files this under *Input Monitoring*.
- Accessibility is used to ask what element is under the cursor; nothing else.
- No network access, no telemetry. The only log is `~/Library/Logs/MacLister.log` (start-up status; clicks only
  with `debugHitTest`).
- The app is **not sandboxed** (it must browse arbitrary folders), ad-hoc signed and **not notarized**. It
  therefore cannot be distributed through the Mac App Store.
- Folders such as Desktop, Documents and Downloads trigger the usual macOS file-access prompts.

## Known limitations

No file search, tree view or hex viewer, and archives cannot be browsed like folders (they are extracted).
Dragging uses Finder conventions; spring-loaded folders are not implemented. Password-protected archives report
an error.
