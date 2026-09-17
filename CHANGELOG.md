# Changelog

`MAJOR.MINOR.BUILD`, where the last number counts published builds rather than
bug fixes: it goes up for every build that ships and resets when the minor
moves. A minor is a milestone worth telling someone about; a major is a
breaking change to stored data.

## Unreleased

### Fixed

- **Updating no longer ends every session.** The sessions live in a daemon that
  outlives the app, and the app used to retire any daemon that was not the one
  it shipped with — which after an update is always true, so the terminals and
  the agents in them died on the way. A daemon with sessions in it is kept now,
  scrollback and all; the changeover finishes by itself once the last session is
  closed.

## 0.3.2 — 2026-09-17

### Changed

- **The project header is two lines, not one crowded one.** The name has the
  whole width to itself; the path and the two buttons share the line below,
  since a path can be truncated and a button cannot. Renaming used to happen in
  a field about a word wide, squeezed between the name and the icons.
- **One click on the project name renames it.** It took two, which is a gesture
  nobody guesses at and nothing on that line competes for.

### Fixed

- **Renaming anything while a session runs is possible again.** The focused
  terminal claimed the keyboard on every redraw, and a redraw happens on every
  change to the model — so with an agent writing output, the caret was pulled
  out of the field several times a second and the name could not be typed. The
  terminal now takes the keyboard only when nothing else in the window is
  taking text; clicking the terminal still works, because that asks outright
  rather than as a side effect of drawing.
- **A project is called what its folder is called.** A directory named
  `botica-web` was added as `nuxt-app`, because `package.json` was allowed to
  overrule the folder — and what `package.json` says is what the scaffold wrote
  there: every Nuxt app is `nuxt-app`, every Vite one `vite-project`, until
  somebody edits it, and nobody does. The name and the path beneath it
  disagreed on the same screen. Projects already added keep the name they have;
  Project Settings renames them.

## 0.3.1 — 2026-09-17

### Added

- **SSH hosts can be added, edited and deleted from the list.** Until now the
  panel could only read `~/.ssh/config` and connect to what it found there, so
  every new machine meant leaving the app for an editor. The list now carries a
  plus, and every row a pencil and a bin.
- **Edits go into the config OpenSSH itself reads.** A host added in Relay is a
  host `ssh` reaches from any terminal, and a host edited in Relay is edited
  where it was already written — including in a file pulled in by `Include`,
  which is where a work machine usually keeps them. Nothing is kept in a list
  of Relay's own, because a second place to look is a second place to be wrong.
- **The rest of the file is left exactly as it was.** Only the lines of the
  block being changed are rewritten, so comments, blank lines, the order of
  directives and somebody's preference for `Hostname` over `HostName` all
  survive. Directives Relay has no field for — `ControlMaster`,
  `ServerAliveInterval`, anything — are shown in a text box and written back
  untouched, so the editor cannot become a way of deleting what it does not
  understand. Before the first write, a copy of the file is kept beside it as
  `config.relay-backup`.

- **The config file itself is one click away.** A form is the quick way to add
  a machine; it is not the way to write a `Match` block or move twenty hosts
  around. The list now opens `~/.ssh/config` in a Relay session with whatever
  `$EDITOR` says, and a host's context menu opens it at that host's own block.
  Neither replaces the other: the form knows what a host usually needs, the
  file knows everything else.
- **A key's passphrase is asked for once, in a dialog, and then never again.**
  The prompt people actually meet is not the server's password but their own
  key's. The host editor now shows which key the host would authenticate with
  and whether `ssh-agent` is holding it; when it is not, one button opens a
  sheet, and what is typed there goes straight to `ssh-add
  --apple-use-keychain`. From then on the login keychain remembers it and `ssh`
  reads it back by itself — Relay is not in the loop at all, and never was:
  the passphrase is never written to a file, never passed as an argument and
  never put in the environment, each of which any other process of this user
  could read. A second button offers the `Host *` settings that make that
  survive a restart.

- **A development build that can be worked in without ending your day.**
  `make dev-install` produces Relay Dev: its own identity, name, icon, data and
  daemon, standing beside the released app rather than replacing it. Before
  this there was no safe way to use Relay for real work while changing it —
  the client retires a daemon whose binary is not the one it shipped with, and
  that hash changes on every build, so launching a freshly built app shut down
  the daemon holding every session that was being worked in.

- **The first project is added from the middle of the window.** With nothing
  in it, the only thing to do was a plus at the foot of an empty strip — the
  smallest target on screen for the one action available. The welcome pane
  carries the button now, and the rail grows its own back once there is
  something to add to.

### Fixed

- **Restarting a session starts the same session again.** It was rebuilt from
  the kind alone, so everything else was thrown away: an SSH connection came
  back as a bare `ssh` answering with its usage message, an agent started with
  arguments came back without them, a session opened in a subdirectory came
  back in the project root under a new name, and a service came back as an
  ordinary terminal its own panel no longer recognised. The daemon knew all of
  it the whole time; the button simply never asked.
- **An SSH session no longer reports the branch of the Mac it was started
  from.** Every session row carried the project's git branch and diff, so a
  connection to somebody else's server sat under `master +589 −36` — true about
  the wrong computer. An SSH row now says where it is connected instead,
  `user@host` as the configuration spells it.
- **Connecting to a host closes the host list.** It started the session and
  then stayed open in front of it, so every connection ended with dismissing a
  panel that had already done its job. The command palette and the branch list
  have always closed themselves on the way out; this one had not.

### Changed

- **Opening the diff leaves the panel the width it was.** It used to widen the
  right-hand panel to fit a line of code, which is a reasonable width and not
  ours to impose: the panel is dragged to a size on purpose, and a button that
  moves the window's furniture as a side effect of showing something is a
  button nobody can predict.

## 0.3.0 — 2026-09-16

### Added

- **A TODO panel, after Git in the right-hand strip.** It searches the
  project's comments for the words it marks unfinished work with — `TODO`,
  `FIXME`, `HACK`, `XXX` and `BUG` unless the project says otherwise — and
  lists what it finds with the file and line each one sits on. A note written
  in a comment is written to be found later, and later never arrives, because
  nobody greps their own codebase for the word.
- **Notes can be handed to an agent.** Tick the ones that belong together,
  write what should be done about them, and send it to the agent already
  working or to a new one; it lands in the prompt unsent, the way a review
  does, so it can be read over first. Each row also carries a button that
  opens it in the project's editor, at its line.
- **Which words count is a project setting.** A codebase that marks its work
  some other way has no other way to be found. Set it in Project Settings, or
  from the gear in the TODO panel itself — a list you are looking at is where
  you notice it is looking for the wrong things. Both write the same setting,
  so neither can go stale while the other is used.
- **Projects that build a Mac app are drawn with their own icon.** The search
  for a project's mark knew every way a website carries one and no way a native
  app does, so a repository with an `AppIcon.icns` in `Resources` was shown as
  two letters over a colour.

### Fixed

- **The app no longer dies when it cannot find its own string table.** Looking
  a word up was the first thing the menu bar did, before any window existed,
  and the lookup trapped rather than returned — so a bundle assembled or
  unpacked wrong did not start in English, it crashed with a stack trace
  blaming a menu. The keys are the English text, so there is always something
  readable to fall back to. The build script now also refuses to assemble a
  bundle without the strings in it.
- **Every project tile has an outline.** It was drawn under the artwork rather
  than over it, so any icon that filled its tile painted over the very line
  meant to contain it — and those were the tiles that most needed one.
- **The project rail draws every icon at one size.** The inset was the same for
  every project and the artwork was not: an application icon fills its canvas
  and a logo exported for a readme carries a third of its width in empty space,
  so one was drawn half the size of the other. Artwork is now trimmed to what
  it actually draws, and an icon that is a tile in its own right is drawn edge
  to edge instead of on a plate inside a plate.
- **The TODO list no longer shows the project its own test data.** A line of
  code that quotes a comment — `"a.swift:9:// TODO: earlier"` in a fixture — was
  read as the comment it quotes, so the panel filled with fragments ending in
  stray quotes and brackets. A marker inside a string literal is a value, and
  the search now says so — including inside a Swift raw string, whose whole
  purpose is that nothing in it means anything.
- **The TODO list no longer lurches when it is overscrolled.** Every row
  carried Relay's own tooltip, which measures the control it is attached to and
  reports its position as the list moves — a hundred of those talking at once
  during a scroll is the scroll. Rows now use the system's tooltip, which costs
  nothing, and are a uniform height, so the list no longer revises its guess
  about how tall it is mid-gesture.
- **Docker's stack controls sit on the section's own line.** Up, down, restart
  and logs had a strip of their own under the heading, at a size nothing else
  used — a toolbar for a section that already had one. They are now beside the
  refresh button, at the size every other panel action is drawn at.
- **Panel buttons are all one size.** The actions in the right-hand panels were
  drawn at 18, 20, 22 and 24 points depending on where they had been added, and
  the send button used a different glyph ratio again, so it read a size larger
  than the button beside it.
- **The ahead and behind counts are the same colour wherever they appear.** The
  project tile drew commits to push in green and commits to pull in blue, and
  the Git panel drew both in grey — the same two facts, stated twice, looking
  like two different ones.
- **The Git tab works from the moment the window opens.** It used to wait for
  the session daemon to start and then for the first poll twelve seconds later,
  and until both had happened it was disabled and claimed the project was not a
  repository. Whether a project holds one is a question for the filesystem, and
  it is now asked before anything else is started.

### Documentation

- **The readme says to move the app before opening it.** macOS runs a freshly
  downloaded app from a temporary copy until it is moved, and that copy is
  where it fails to find parts of itself. The step was missing, and it is not a
  tidiness one.
- **The readme installs the app instead of building it.** It opened with Xcode
  version requirements and a `git clone`, which is a door most people will not
  walk through to try something. It now points at the releases page; building
  from source has moved to the development section, where it was always the
  audience.

## 0.2.1 — 2026-09-16

### Changed

- **Clicking a container opens a prompt inside it.** It used to open the
  container's log, which is something you ask for rather than the thing you
  came for — getting inside is. Bash where the image has it and `sh` where it
  does not, which is most of them. A container that is not running has nothing
  to step into, so it still opens the log, which is the only account of why it
  stopped. Both stay in the right-click menu.

### Fixed

- **Arrowing through a list left the list where it was.** In the branch window
  and the command palette the highlight walked off the bottom and carried on
  going, so the keyboard was somewhere the window was not showing — while the
  ports and SSH windows followed it, which made it look like a list that
  sometimes worked rather than two that never did. All four follow it now.
- **Compose Up reported that the project had no Compose file, with that
  project's containers listed beside the button.** Relay looked for the four
  names Compose looks for and gave up, while a stack split into
  `docker-compose.local.yml`, `.stage.yml` and `.prod.yml` has none of them.
  Docker writes the file it was given onto every container it creates, so the
  running stack is now asked rather than guessed at, and the file and the
  project name are passed to Compose rather than left to whichever directory the
  command started in — which is what made Up act on a different stack than the
  one on screen. When nothing is running the search knows the environment
  suffixes too, preferring the local one and never a production file: the file
  this picks is the one the button starts.
- **Relay reads containers from the engine itself rather than from the `docker`
  command.** Every engine on a Mac serves an HTTP API on a unix socket, and
  Relay now asks that directly — which means the panel fills for whichever
  engine is actually running rather than for whichever one a CLI context points
  at, without needing a `docker` binary on a PATH that a daemon launched by the
  GUI never inherits, and without starting a process every few seconds for as
  long as the panel is open. Docker Desktop, Colima, OrbStack and Rancher
  Desktop are all looked for, as is an explicit `DOCKER_HOST`. Compose is
  unchanged and still goes through the CLI: it is a client-side tool with no
  presence in the engine's API at all.
- **The Docker panel answered a closed engine with four lines about a socket
  path.** It is one thing — nothing is running — and it is now said in one
  line, with a button that starts what Relay found: Docker Desktop, or Colima
  for a machine that would rather not run a desktop app at all. A machine with
  no engine installed gets neither a button nor the socket, but the one
  sentence that applies: Relay shows the containers an engine is running and
  does not carry one. Anything Relay has not been taught to read is still
  passed on word for word, because an error it cannot name is one it must not
  paraphrase.
- **A project's status dot was missing its right-hand side.** The tile drew it
  three points outside its own frame, which works exactly as long as nothing
  laying the tile out clips — and the tile carries a context menu, which does.
  The dot sits inside the tile now, where the ring around it was already doing
  the job of separating it from the artwork.
- **Panels showed what was true when they were opened.** Containers are started
  in Docker Desktop, files are written by agents, branches are checked out in a
  terminal — none of which Relay is told about, so the Docker panel, the review
  panel, the branch window and the history list each sat on an answer from
  whenever they had last been asked. They keep themselves current while they are
  on screen now, and stop the moment they are not. An answer that has not
  changed is not applied, so a panel nobody is touching does not redraw, and a
  diff being read does not reload under the reader.

## 0.2.0 — 2026-09-16

Reviewing what an agent just did, beside the terminal it is still running in.

### Added

- **Review what an agent changed without leaving Relay.** The Git panel lists
  the working copy — conflicts, staged, and everything still in flight — and
  `⌘G` opens the review window: files on the left, the diff of the one you
  picked on the right, with staging, unstaging, discarding and committing where
  you are already looking. Discarding asks first, because for an untracked file
  it means deleting it.
- **Terminals draw on the GPU.** Scrolling a full window of text was redrawing
  every glyph on the CPU, which is exactly the work a graphics card exists for;
  the same scroll now costs a fraction of it. A machine that cannot manage it
  falls back to the old path on its own, and the switch is in Settings →
  General → Terminal for one that can but should not.
- **`⇧↩` starts a new line instead of sending the prompt.** A terminal sends a
  bare carriage return for Return whatever is held down with it, so an agent
  cannot tell the two apart — which is why other terminals have to be
  configured by hand. Relay sends the sequence that means "another line" itself,
  and leaves the keystroke alone for a program that has asked to see modifiers
  on its own.
- **The terminal text size can be changed**, with `⌘+`, `⌘-` and `⌘0` for the
  size it started at, in the View menu, and in Settings. It applies to every
  terminal at once and survives a relaunch.

### Changed

- **⌘P finds a command by whatever you call it.** The palette used to match the
  text on screen, character for character, so an interface in Russian could not
  be searched in English — «Переключить ветку» was invisible to "branch" — and
  neither could an interface in English be searched in Russian. It now matches
  every language Relay ships, reads a query typed on the wrong keyboard layout
  ("икфтср" is "branch"), understands Russian written in Latin letters
  ("vetka"), tolerates the ending of an inflected word, accepts letters in order
  without being together ("swbr" finds Switch Branch), and orders what it found
  by how well it fits rather than by where it happens to sit in the list. The
  shortcut list in Settings searches the same way.
- **Releases are signed with Developer ID and notarised by Apple.** Until now a
  build carried a development certificate, which signs an app for the machine
  that made it: every other Mac refused to open it without being talked round in
  System Settings. `./Scripts/release.sh` now builds, signs, notarises and
  staples, and produces both the archive the in-app updater downloads and a disk
  image to drag into Applications. Because the signing identity changes, macOS
  will ask once more for the permissions it has already been given.

### Fixed

- **The pointer never changed shape.** Every button, row, tab and field kept the
  arrow, so nothing on screen admitted to being clickable until it was clicked.
  The shape was declared with an AppKit cursor rectangle registered on a view
  sitting behind the SwiftUI content, and on a current macOS that view is never
  consulted: the rectangle was registered and then never applied. SwiftUI has
  stated the pointer itself since macOS 15, and Relay now says it that way,
  keeping the old route for macOS 14. The places that had never declared a shape
  were filled in at the same time — switches, pop-up menus and the header that
  collapses a section show the hand, text fields the caret, a pane's header the
  open hand it is dragged by — and the divider between two panes holds the
  resize pointer through a drag that outruns it.
- **The context line under a terminal went missing.** The readers were pointed
  at the panes as they were a moment *before* the session was shown, so the
  terminal in front of you was never the one being read — the figure appeared
  for whatever had been on screen previously. They now follow the panes as they
  change, and a newly shown terminal is read at once rather than at the next
  ten-second tick.
- **A freshly started agent had no context line at all**, while the pane beside
  it had one — which reads as a broken pane rather than as a session nobody has
  spoken to yet. The row is now under every agent terminal, showing a dash until
  there is something to read: the CLI writes its transcript as it answers, so
  before the first reply the figure exists nowhere to be read from.
- **The context bar's tooltip appeared in the middle of the terminal.** The bar
  is a strip the width of the pane, but only its left end is drawn on — and the
  button underneath ran the whole width, so the label describing the numbers
  floated above the empty half, and a click on blank strip opened the panel. The
  control is now as wide as what it shows, and says nothing at all while the
  panel it opens is already up.
- **A resumed conversation showed no context figure.** Resuming appends to the
  transcript the earlier conversation left behind, so the file is always older
  than the session reading it, and Relay — which matches a session to the
  transcript that began alongside it — found nothing. The command says which
  conversation it is resuming, and that is now what is looked up.
- **The palette described a session in English** while every other place showing
  a status had it translated.

## 0.1.0 — 2026-09-15

The first release.

### Added

- **Every past conversation, not just Relay's own.** The History panel now lists
  the Claude and Codex conversations belonging to a project — read from the
  agents' own transcripts, so it is the same list their `/resume` offers,
  whether the conversation was started in Relay or in a terminal. Clicking one
  resumes it: the agent continues where it left off rather than starting again.
- **How full each agent's context window is**, under the terminal it belongs to:
  a meter, the percentage and the token count, with the breakdown behind a
  click — what is cached, what was sent fresh, what the reply and its reasoning
  cost. Read from the transcripts the CLIs write as they go, so nothing is asked
  of anyone and the figure cannot disagree with the agent's own.
- **Clicking the usage opens it properly.** The popover always shows every
  window — it is where you go to look properly — and its Detailed/Compact switch
  governs the bar alone. The bar starts compact, keeping one line per agent: the
  window nearest to running out rather than the shortest one, because that is
  the limit that will actually stop you. Hovering the bar still lists them all.
- **A status bar along the bottom** showing what each agent has left of its rate
  limits: a meter per window, the percentage, and how long until the nearest one
  rolls over. The figures come from the CLIs' own caches on disk, so they cannot
  disagree with what Claude Code or Codex would tell you, and Relay asks nobody
  for them. It appears only when there is something to report, and can be turned
  off in Settings.
- **Relay updates itself.** It asks GitHub for the newest release on launch and
  every six hours; when one is newer than the running build a pill appears in
  the title bar, and clicking it downloads, checks and installs the new version,
  then restarts into it. Sessions are untouched — they belong to the daemon.
  The check lives in Settings → About and can be turned off, which stops the
  request rather than hiding its answer; it carries a user agent and nothing
  else.
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

- **Versions are numbered the way a continuously updated app is.** The last
  component is a build counter, not a bug count: it goes up for every published
  build and resets when the minor moves. `0.2.47` is the forty-seventh build of
  the 0.2 line. `Scripts/bump-version.sh` moves it on, so "is this enough for a
  release?" — a question about nothing — never has to be answered again.
- **`⌘R` no longer starts the dev service.** It means reload everywhere else on
  the machine, and Relay will want it for reloading something of its own. The
  command keeps its place in the menu and the palette, and can still be given a
  key by hand; restarting stays on `⌥⌘R`.
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
  branch with a working-tree diff. The working directory is gone from the row:
  it is already in the project header.
- **New right-hand panel** with icon tabs for Services, Docker and History, plus
  disabled placeholders for Git and Files so the shape of the app is honest
  about where it is going. Toggles with `⌥⌘B`.
- **SSH moved to its own window** (`⇧⌘S`). Hosts describe the machine, not the
  repository, so they no longer take up room in a project sidebar.
- **The Project section is gone.** Its one useful fact, the branch, now sits
  under the path in the header.

### Fixed

- **A resumed conversation refused to save its transcript.** Relay handed every
  session its own environment, markers and all — so an agent started from Relay
  inherited the identity of whatever agent session had launched Relay, decided
  it was that session's child, and turned its own transcript saving off. A
  session now starts as though from a fresh login shell.
- **A new session showed another conversation's context.** Relay matched a
  session to the most recently written transcript in its directory, which for a
  freshly opened pane was whichever long conversation was busy — so an empty
  session read 93% full. It now matches the transcript that began when the
  session did, and reports nothing when there is none.
- **An agent at work could read as idle.** Whether a session is working was
  being inferred from the timing of its output, so an agent whose spinner
  redraws slowly looked like one doing nothing. Every agent says it is busy by
  offering a way to interrupt, and Relay now reads that instead — with a
  question on screen still outranking a spinner behind it.
- **The state line in a session row comes and goes no longer.** It was shown
  only when there was something to say, which changed the row's height as an
  agent worked and left "what is this doing" answerable only by a dot.
- **Closing sessions froze every other one.** Tearing a session down waited for
  its process to be reaped, on the same queue that carries terminal output — so
  closing a project with ten sessions could hold every pane for five seconds.
  The wait now happens where it cannot be felt.
- **The project's default agent now does something.** It was written down and
  read back by its own settings row and by nothing else — a control that
  pretends. It decides which start on the project screen is the prominent one.
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
