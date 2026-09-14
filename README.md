# BCTask

A lightweight native macOS menu-bar todo app with a dark/cyan interface.
It lives in the menu bar, toggles a movable main surface on repeated menu-bar
clicks, supports list and kanban views, archives completed tasks after one
hour, exposes the archive, and can pin any task in an always-on-top floating
panel.

## Requirements

- macOS 13.0 or later
- Apple Swift toolchain (developed and verified with Command Line Tools only;
  no full Xcode required)
- No third-party dependencies

## Build and test

- `scripts/test.sh` — canonical test runner (110 Swift Testing tests). Bare
  `swift test` silently discovers zero tests on CLT-only machines because the
  Swift Testing framework lives outside the SDK; the script derives the needed
  framework/plugin paths from the active developer directory, passes them to
  every target, and fails unless both discovery canaries actually ran and the
  summary clearly reports a passing nonzero test count.
- CLT-only retry policy: on a CommandLineTools developer dir, the SwiftPM test
  helper can lose the trailing summary after the test process exits normally
  (`swift test` status 0, no `Test run with N tests` line — the known helper
  stream-loss defect, see `.slim/debug/swift-testing-midrun-exit.md`). The
  wrapper retries ONLY that shape of run, up to 12 attempts total, labeling
  each retry `CLT transport retry N/12`. A nonzero `swift test` status, a
  zero/nonpassing summary, or a complete summary missing a discovery canary
  fails immediately with no retry. A full-Xcode (or unknown) developer dir
  runs exactly one attempt; that branch is unverified in this environment
  (CLT-only host).
- `swift build` — debug build.
- `swift build -c release` — release build.

## Install and run the app

- `scripts/install-app.sh` — one-command user-local install (default
  `release`). It builds, assembles, and signs the bundle via the canonical
  `scripts/make-app.sh`, then installs (or replaces) it at
  `${BCTASK_INSTALL_DIR:-$HOME/Applications}/BCTask.app` without sudo. It
  never deletes anything outside that exact destination bundle, keeps paths
  with spaces working, requests Spotlight metadata import and
  LaunchServices registration when those system tools are present
  (nonfatal if the indexing tool declines), and prints exact
  launch/reinstall guidance.
- `scripts/install-app.sh debug` — install a debug build instead.
- `scripts/make-app.sh [debug|release]` — only assemble the `.app` bundle
  in `.build/BCTask.app` (asserts `LSUIElement=true`, the plist minimum OS
  (13.0), the executable's Mach-O minimum OS, and strict signature
  verification) without installing it.

Launch the installed app:

```sh
open -a BCTask
# or, explicitly:
open "$HOME/Applications/BCTask.app"
```

Behavior notes:

- **Spotlight discovers only the installed app.** A bundle left in
  `.build/` is not registered with LaunchServices and will not appear in
  Spotlight search; install with `scripts/install-app.sh` so Spotlight and
  `open -a` both find it.
- **Reopening while running surfaces the main panel.** Launching BCTask
  again while an instance is already running (Spotlight, Finder double
  click, or `open -a BCTask`) now brings the already-running instance's
  main task surface forward instead of doing nothing; no second process is
  started.
- **Menu-bar-only live feel.** Launching the app shows and focuses the main
  surface immediately; there is no Dock icon and no app-switcher entry, and
  the menu-bar item is an image-only checkmark (a checkmark SF Symbol with
  "BCTask" as its accessibility label/tooltip, no visible title text next
  to the icon).

Signing remains local **ad-hoc** (the environment has no distribution
identity); the installed app runs on this machine but is not a
distributably signed artifact.

## Using BCTask

- An image-only checkmark appears in the menu bar (its accessibility
  label and tooltip are "BCTask"). **Left-click** toggles the main task
  surface; **right-click** (or Control-click) opens a small menu with
  Show/Hide and Quit. The app is menu-bar-only: no Dock icon, no app
  switcher entry.
- The main surface is one retained, movable, resizable window (minimum
  720×520, opening at 860×680). Its position and size persist between
  launches. Hiding it does not rebuild its content, so draft text and
  focus survive toggles.
- The archival catch-up sweep runs at launch, periodically while running,
  when the app becomes active, and when the Mac wakes or the session becomes
  active, so completed tasks archive on time even after sleep.
- Pin/unpin any task to open a floating always-on-top panel for it. Pinned
  panels stay visible across Spaces and full-screen apps, keep their own
  persisted position per task, and close (unpinning the task) when you close
  them. Pin state persists across launches. `Command-P` pins or unpins the
  focused task.
- Any task (active or archived) can be deleted permanently with the trash
  button on its row, or with `Command-Delete` for the focused task. Deletion
  is immediate — there is no archive step and no undo. Deleting a pinned task
  also closes its floating panel.
- The pin now mirrors "currently in Doing": moving a task to Doing pins it
  automatically and its floating panel opens; moving it to Todo or Done unpins
  it and the panel closes. Manual pin/unpin (button or `Command-P`) still works
  and lasts until the task's next status change.
- In Kanban, drag a card onto any part of another Todo, Doing, or Done column
  to change its status. Empty columns and the whitespace below cards are drop
  targets. Dragging never manually reorders cards within a column; the existing
  most-recently-updated ordering remains authoritative. Status buttons and
  menus remain available as non-drag alternatives.

### Keyboard shortcuts (while the main surface is key)

- `Command-N` — focus the new-task field
- `Escape` — while editing, leave the new-task field without clearing its
  draft; otherwise hide the main panel (the app remains available in the menu
  bar)
- `Tab` — toggle List ↔ Kanban while viewing active tasks
  - While typing a new task, Tab is intentionally ignored. Press `Escape`
    first, then `Tab` to switch views.
- `Up` / `Down` — move task focus
- `Command-Left` / `Command-Right` — move the focused task backward/forward
  through Todo → Doing → Done
- `Command-P` — pin or unpin the focused task
- `Command-Delete` — delete the focused task (while typing a new task,
  Command-Delete keeps its standard text behavior and is not a delete
  shortcut)

## Project layout

- `Sources/BCTaskCore` — domain and persistence (`TaskStore`, `TaskItem`,
  document codec, file store).
- `Sources/BCTask` — application: SwiftUI views, `AppModel`, and the AppKit
  status-item/panel/lifecycle controller (`StatusItemPanelsController`,
  `KeyCommandTranslator`).
- `Tests/BCTaskCoreTests`, `Tests/BCTaskAppTests` — domain, persistence, and
  app-behavior tests (Swift Testing).
- `scripts/test.sh`, `scripts/make-app.sh`, `scripts/install-app.sh` —
  canonical test runner, bundle assembly, and user-local installer.

## Known limitations

- Ad-hoc local signing only (see above).
- On this CLT-only machine, the full-Xcode Swift Testing path is unverified;
  tests run through `scripts/test.sh`.
- Interactive menu-bar click behavior (left toggle / right menu) and pinned
  panel visibility across Spaces were validated by design and smoke launch,
  not by UI automation.
