# Changelog

Versions follow [semantic versioning](https://semver.org). Nothing has been
released yet: 0.1.0 will be the first release, cut when the app is ready rather
than when a day of work ends. Until then everything lands here.

## Unreleased

### Added

- **Projects wear their own icon.** A repository nearly always ships a favicon
  or an app icon, and it says which project this is far better than two letters
  over a colour. One can also be chosen or dropped in the project's settings.
- **A control under the keyboard looks like a control under the pointer**, and
  carries an accent ring on top: one shade of grey away from near-black is not
  an answer to "where am I".
- **Left and right walk a row's actions.** Up and down pick the port or host,
  left and right move along what that row can do, Return runs it. Arriving on a
  row always starts from its first action, so Return is never a keystroke away
  from killing a process you had not looked at. Settings changes section with
  the same keys.
- **The panels take the keyboard.** Arrows move through the ports and hosts,
  Return acts on the highlighted row, Escape closes. The highlight stops at the
  ends rather than wrapping, and follows the list when filtering shortens it.
- **Ports, SSH hosts and Settings open over the window** instead of as separate
  windows with their own traffic lights. Escape or a click outside puts them
  away, and the shortcut that opened one closes it.
- **The Docker tab can be asked again.** A project whose containers were not
  running when it was opened left the tab off with no way to re-check short of
  restarting. Clicking it now probes again, with a spinner while it does, and
  opens the tab if anything turned up.
- **A stop button on every port row**, rather than only in its context menu.
  Relay's own processes stop on the click; anything else still asks first.
- **The right-hand panel resizes**, and its width is remembered.
- **Splitting is visible, not just bound to a key.** Every pane header carries
  split-right and split-down buttons, and a session can be dragged — from the
  sidebar or by its own header — onto any pane. The half it will occupy is
  previewed while the pointer moves: the four edges divide, the middle takes the
  pane over. A session dragged across a split moves rather than appearing twice.
- **The rename field says how to leave it.** Renaming a session — or a project,
  by double-clicking its name in the sidebar header — now offers a tick and a
  cross beside the field, and puts the caret there without a second click.
- **Split terminals.** `⌘D` splits right, `⇧⌘D` splits down, `⌥⌘]` moves focus
  between panes. Dividers drag, the arrangement is remembered per project, and a
  pane whose session has gone is dropped rather than left blank. Choosing a
  session from the sidebar shows it in the focused pane instead of tearing the
  split down, the same as opening a file into the active editor.
- **Where a port came from.** Each listening process reports its working
  directory, so two `node` servers on 5173 are finally distinguishable. Rows are
  named after the project the directory belongs to, and the path is searchable.

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

- **One mechanism for every panel and dialog,** not just one frame. The project
  settings, the add-project dialog and the two editors were SwiftUI sheets: they
  opened differently, and a click outside did nothing. They are all panels now,
  closing on Escape or on the overlay. A panel opened from inside another —
  the preset editor lives in Settings — returns to it rather than to nothing.
- **One frame for every panel and dialog.** Ports, hosts, settings, the project
  sheet and the two editors were each built by hand and had drifted: the same
  dialog was tighter at the top than at the bottom, and no two of them agreed.
  They now share a surface, with generous insets that match.
- The traffic lights sit on the centre line of Relay's own title bar rather than
  the shorter one macOS would have drawn.
- One draggable divider for the whole app. The sidebars and the splits each drew
  and handled their own, and only one of them had a hover state — or moved at
  the speed of the pointer.
- The project screen offers your own presets rather than a hardcoded trio, each
  with its agent's real mark, and shows the branch with a Git glyph.
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

- **Russian windows still spoke English in places.** Around forty phrases never
  reached the translation table at all — section headings like "All hosts", the
  empty states, every field label in the dialogs, the command palette's entries,
  the keyboard recorder, and every notification Relay sends. A test now reads the
  source and fails on any phrase the app looks up and the table does not have,
  which the previous check — the two tables agreeing with each other — could
  never catch.
- **"Session … is not known to the daemon" appeared out of nowhere.** Closing a
  pane while the daemon was still answering the request that created it put the
  session back: the reply arrived after the decision, reinstated it, and
  attaching then failed. A closed session now stays closed, whatever is still in
  flight about it — and an attach that finds no session quietly drops it instead
  of raising an error nobody can act on.
- **An idle agent flickered between Working and Idle.** Every byte of output
  counted as work, and a terminal interface repaints while doing nothing at all.
  Work is sustained output now; a repaint is a blip.
- **Dragging a divider oscillated instead of resizing.** The drag was measured
  against the handle, which is the thing that moves: each event moved the
  divider to the pointer, the pointer then appeared not to have moved, and the
  divider was put back. Drags are measured against the window now, and land on
  whole points.
- **A split pane's header fell apart.** Written for the full window, it wrapped
  the session name down the pane and grew tall enough to push the terminal off
  screen. It now drops what will not fit — the pid, then the status text — and
  keeps its height.
- **Clicking a terminal did not focus its pane**, because the terminal is an
  AppKit view and consumes its own mouse events, so `⌘D` always split whichever
  pane the sidebar had last selected.
- **Splitting could flatten an existing layout** when the pane it was aimed at
  had gone.
- **Splitting a pane froze the window.** Drawing a pane asked the model for its
  terminal renderer, and that call recorded the session as recently used — a
  write that invalidated the very view which had just read it, so every draw
  scheduled another. One pane happened to settle; two kept each other going at
  100% of a core. The renderers are a cache rather than state the interface
  watches, and now live outside it.
- **Typing landed in the wrong pane.** Every pane claimed the keyboard on every
  update, so two of them traded it back and forth.
- **`docker compose up` failed with "no configuration file provided"** for any
  project keeping its stack in a subdirectory. Compose now runs where the file
  actually is, and a project with no compose file is not asked about one.
- Localised labels re-resolved their `.lproj` and reopened a bundle on every
  redraw, and the startup hint kept a timer redrawing a whole terminal pane
  forever to say nothing.
- **Terminals took a minute to start, and often never did.** Two separate
  faults, both of which left a session at "Starting" with nothing on screen.
  The app's event stream was closed for good the first time the daemon
  connection was rebuilt — which happens on every launch that retires an older
  daemon — so replies kept working while every status change and every byte of
  terminal output was silently dropped. And the daemon answered `lsof`, `docker
  ps` and `docker compose up` on the same serial queue that carries PTY output,
  keystrokes and session creation, so pressing Start in the Docker tab froze
  every terminal in the app until the command returned.
- **Session rows twitched under the pointer.** The close button was being
  inserted on hover, pushing everything beside it; it now holds its place and
  only fades in, as do the other hover-revealed row controls.
- `⌘\\`, `⇧⌘S` and `⌘,` only ever opened their window. They now toggle: front
  and focused closes, anything else brings it forward.

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
