# Changelog

Versions follow [semantic versioning](https://semver.org): a breaking change to
stored data or the daemon protocol bumps the major, a feature bumps the minor, a
fix bumps the patch.

## 0.4.0

### Added

- **A real title bar** spanning the window, with a command-palette search field
  in the middle, sidebar toggles on the left and project controls on the right.
  It also owns dragging and double-click-to-zoom, which is why those never
  worked reliably before: the behaviour was scattered across three panel
  headers that each also held buttons.
- **Notification inbox** in the title bar. Agents waiting on you, failures and
  finished work collect there with an unread badge, so a banner missed is not a
  notice lost. Clicking one jumps to its session.
- **Add Project sheet** with a drop target, and the project rail accepts a
  dropped folder directly.
- `⌘B` toggles the sessions sidebar; `⌥⌘B` toggles the project panel.

### Fixed

- An expanding drag region stretched the sidebar, the project panel and the
  terminal header, pushing their contents down the window.
- Only the glyph inside an icon button was clickable, not the button.
- A bare trailing closure on a section header bound to the wrong parameter, so
  the header's button was silently dropped.
- Closing a session waited on the daemon before the row disappeared.
- The build failed on Swift 6.1, which is what CI runs.
- A test asserted that the machine had unrelated listening ports, which is not
  true on a clean runner.

## 0.3.0

Interface restructuring, and the fixes that came out of using it.

### Changed

- **Left sidebar is sessions only.** Each row now carries the agent's own mark
  with its status riding on it, the session name, what it is doing, and the
  branch with a working-tree diff — the shape Warp uses. The working directory
  is gone from the row: it is already in the project header.
- **New right-hand panel** with icon tabs for Services, Docker and History, plus
  disabled placeholders for Git and Files so the shape of the app is honest
  about where it is going. Toggles with `⌥⌘B`.
- **SSH moved to its own window** (`⇧⌘S`). Hosts describe the machine, not the
  repository, so they no longer take up room in a project sidebar.
- **The Project section is gone.** Its one useful fact, the branch, now sits
  under the path in the header.

### Added

- **History** of finished runs per project: what ran, for how long, how it
  ended, and a one-click rerun.
- Working-tree diff statistics next to the branch.
- Builds are signed with a real certificate when one is available, so macOS
  stops re-asking for folder permissions after every rebuild.

### Fixed

- Docker containers were only found when a compose file sat in the project root.
  They are now matched by Compose's working-directory label, so a stack in
  `<project>/docker` under an unrelated project name is picked up.
- The window drag region covered the whole header, so clicking the project
  settings button zoomed the window instead.
- Settings did not open at all: a short-circuited condition returned before
  sending the action.

## 0.2.0

The rest of the v0.1 scope from the spec, plus the workflow around it.

### Added

- **Services** — start, stop, restart, logs, automatic port detection and Open
  URL, seeded from the project's `package.json`.
- **Ports** — a window listing every TCP port on the machine, with the ones
  Relay started attributed to their session.
- **Docker** — containers for a project, discovered through Compose labels, with
  start, stop, restart and logs.
- **SSH** — a window listing hosts from `~/.ssh/config` including `Include`
  directives, with per-project pinning.
- **Notifications** — for agents waiting on input, failures and completions,
  with global, per-project and per-type opt-out.
- **Settings window** with rebindable shortcuts and conflict detection.
- **Session presets** behind the sessions `+`, defaulting agents to their own
  automatic-approval flag.
- Sessions name themselves from the terminal title the running program reports.
- Tooltips showing both the action and its shortcut.

### Fixed

- Sessions were spawned without a controlling terminal, so interactive CLIs
  rendered nothing.
- `Terminate` sent SIGHUP into a process that had inherited an ignored
  disposition and silently did nothing.
- Status classification depended on how the PTY happened to split output.
- Spawned processes inherited the daemon's log handle and its IPC sockets.
- A daemon left running from a previous build kept serving stale behaviour.
- Releasing a suspended dispatch source aborted the app whenever a handshake was
  rejected.
- Session numbering climbed forever, so a lone session could be called
  "Claude 4".

## 0.1.0

First working milestone: the session daemon, projects, sessions, the terminal,
status detection and the dark UI.
