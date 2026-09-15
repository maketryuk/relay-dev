# Changelog

Versions follow [semantic versioning](https://semver.org). Nothing has been
released yet: 0.1.0 will be the first release, cut when the app is ready rather
than when a day of work ends. Until then everything lands here.

## Unreleased

### Added

- **The app's own icon and mark.** An open ring with a dot resting in its gap:
  the ring is the app, which you can close, and the dot is the process, which
  stays. Traced once from the source SVG and shared by the icon generator and
  the interface, so they cannot drift.

- **Localisation.** English and Russian, switched in Settings and applied
  immediately without a restart. The English text is the lookup key, so a gap in
  a translation shows readable English rather than a raw identifier, and a test
  fails if the two tables drift apart.
- **Session presets are customisable.** The menu offers Terminal, Claude and
  Codex out of the box; Gemini, OpenCode and the supervised variants are one
  toggle away in Settings. A preset you create is always offered.
- **Toasts** in the bottom-right corner for things that happen rather than
  things you asked for: the daemon dropping, a session that would not start, a
  failing `docker` command. Repeats of the same condition replace each other
  instead of stacking, and anything the user has to act on stays until it is
  dismissed rather than expiring quietly.
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
- **History** of finished runs per project: what ran, for how long, how it
  ended, and a one-click rerun.
- Working-tree diff statistics next to the branch.
- Builds are signed with a real certificate when one is available, so macOS
  stops re-asking for folder permissions after every rebuild.
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

### Changed

- One icon control for the whole app. Hover, disabled and selected states were
  being reimplemented per site and drifting — the notification bell had no hover
  while the gear beside it did. Row and header buttons also grew from 16 to 24
  points, which is the difference between aiming and pressing.
- Right panel tab order: Files, Git, History, Services, Docker.
- The Docker tab is disabled, with a reason, when a project has no containers
  and no compose file.
- Project tiles in the rail use Relay's own tooltip, showing the name and the
  aggregated status.
- The connection banner is gone; its job belongs to the toast stack.
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

### Fixed

- **A service could sit at "Starting" forever.** The reply to `createSession`
  carries the session as it was when the daemon answered, and it was overwriting
  the newer state the events had already delivered. For anything that starts and
  then goes quiet — a dev server, exactly — nothing ever arrived to correct it.
- **The window dragged from anywhere in the title bar, buttons included.** A
  SwiftUI hierarchy hit-tests as one `NSHostingView` that reports itself as
  draggable, so AppKit could not tell a button from empty chrome. Relay now
  moves the window itself, only from regions it knows are empty.
- The process id was rendered with a thousands separator: "pid 85 258".
- The window reserved a full title bar's height of empty space above Relay's
  own title bar.
- A toast reporting the daemon going away offered no way to reconnect, which
  the banner it replaced did. Toasts can now carry an action, and the app also
  retries on its own when a daemon stops on purpose — usually it is being
  replaced by a newer one.
- Ports and SSH appeared both in the title bar and in the rail; the palette and
  settings appeared in the rail as well as the title bar. Each now has one home.
- The search field had no hover state.
- History recorded plain terminals alongside agent runs. It is a record of what
  agents did, so shells no longer clutter it.
- An expanding drag region stretched the sidebar, the project panel and the
  terminal header, pushing their contents down the window.
- Only the glyph inside an icon button was clickable, not the button.
- A bare trailing closure on a section header bound to the wrong parameter, so
  the header's button was silently dropped.
- Closing a session waited on the daemon before the row disappeared.
- The build failed on Swift 6.1, which is what CI runs.
- A test asserted that the machine had unrelated listening ports, which is not
  true on a clean runner.



Interface restructuring, and the fixes that came out of using it.
- Docker containers were only found when a compose file sat in the project root.
  They are now matched by Compose's working-directory label, so a stack in
  `<project>/docker` under an unrelated project name is picked up.
- The window drag region covered the whole header, so clicking the project
  settings button zoomed the window instead.
- Settings did not open at all: a short-circuited condition returned before
  sending the action.



The rest of the v0.1 scope from the spec, plus the workflow around it.
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



First working milestone: the session daemon, projects, sessions, the terminal,
status detection and the dark UI. Predates this repository, so it has no tag.
