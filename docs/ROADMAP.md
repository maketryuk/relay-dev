# Relay — roadmap

Status of the work against `SPEC.md`, and what is planned next. Items are
ordered by when they are worth doing, not by size.

---

## Done

### Milestone 1 — foundation

- Session daemon: PTY lifecycle, scrollback, event stream, reconnect.
- Sessions survive quitting the app; history replays on reconnect.
- Session types: Shell, Claude, Codex, Gemini, OpenCode, SSH, custom command.
- Status detection from terminal activity, aggregated to the project.
- Project Rail, Project Sidebar, terminal, Command Palette, dark UI kit.
- Project configuration with git, package manager and dev command detection.

### Milestone 2 — the rest of v0.1

- Diff review: the working copy, file by file, with staging and committing.
- Terminals on the GPU, `⇧↩` for a new line, and a text size that can be changed.

- Services: start, stop, restart, logs, port detection, Open URL.
- Ports: every listener on the machine, attributed to Relay's own sessions.
- Docker Compose: up, down, restart, logs, container status, published ports.
- SSH: `~/.ssh/config` with `Include`, connect, pin hosts to a project.
- Notifications for events that need attention, with three levels of opt-out.
- Settings window, rebindable shortcuts, Relay's own tooltips.

603 tests. The daemon suite drives real processes on real PTYs.

### Releasing

`./Scripts/release.sh` signs with Developer ID, notarises, staples and packages
both the archive the updater downloads and a disk image to drag into
Applications. It needs a Developer ID certificate and notarisation credentials
on the machine that runs it; until those exist, nothing distributable can be
built at all.

---

## Next: v0.2 — Workspaces

The spec's next structural change: `Project → Workspace → Sessions`, where a
workspace is a git worktree.

### Built

- **Worktrees, read from git.** Created in `~/.relay/worktrees`, listed from
  `git worktree list` — so ones made in a terminal or by an agent appear too —
  and removed with a question first when there is uncommitted work. A branch
  goes with its worktree only when Relay made it and git proves its work is in
  the remote's default branch — merged, squashed or rebased in.
- **Sessions belong to a worktree by where they were started.** No protocol
  change was needed: the daemon already reports each session's directory, and
  the deepest worktree containing it is the one it is in.
- **The sidebar groups sessions under their worktree** once there is more than
  one, with the branch and its diff on the heading. A switcher above the list
  was the earlier plan; it would have hidden the agents in every other worktree,
  and "which of them needs me" is the question the list is for.
- **The right-hand panel follows the selected session's worktree**: Git, files,
  search, TODO, definitions and history read that checkout.
- **Clean Up Worktrees…** lists every worktree that could go, with what stands
  in the way of each — a lock, an agent at work, uncommitted files, commits a
  detached `HEAD` alone holds — filters it to the merged, the clean and the
  idle, ticks the finished ones, and removes what is ticked one at a time.
  Nothing goes on its own.

### Still to do

1. **Getting a new worktree ready to run.** Git copies nothing it does not
   track, so a fresh worktree has no `.env` and no `node_modules`. A list of
   files to copy (a `.worktreeinclude`, say) and a setup command per
   project, run as a visible session after creation.
2. **Services per worktree.** A service still starts in the project's own
   folder, whichever worktree is being looked at, and one definition is one
   session per project. Running Dev in two worktrees at once needs the service
   to be keyed by worktree as well.
3. **Automatic ports.** Two worktrees of the same project must not fight over
   port 3000. Find a free port, start the service on it, remember the binding
   and show it next to the worktree. Attributing a listening port to its
   worktree comes first and is nearly free: the daemon already maps ports to
   sessions.
4. **Finishing a piece of work.** A pull request through `gh` and its state on
   the heading — and then in the cleanup window, as a filter and a reason to
   tick a row, once there is a pull request to know about. Telling
   a finished branch from an unfinished one is done, squash and rebase merges
   included, and removing a worktree goes by it. What it does not recognise
   is a pull request the forge had more of than the local branch — a
   suggestion accepted on the forge, a conflict resolved there — or a rebase
   merge whose lines the base has since changed again; those branches are
   kept, and the toast that says so deletes them when asked. Asking the forge
   whether the pull request was merged would answer both.
5. **A session that moves.** `claude --worktree` started from the project's
   folder moves into a worktree of its own, but the session is grouped by where
   it started. Reading the process's current directory would place it where it
   is.

## Then

- **The rest of the editor.** A file opens from the Git panel, the file tree,
  a name in the palette and a search; ⌘-click goes to where a name is declared.
  Still to do: watching the directory so the tree and the open buffers notice
  what an agent wrote, replacing what a search found, and re-parsing only what
  changed rather than the whole file after a pause.
- **Method-level jumps into a Composer dependency.** A `vendor` is indexed by
  file name, which answers for classes and not for what is in them: 17,500
  files and 96 MB of PHP is forty seconds of parsing, and it is spent before
  anybody has asked for it. Reading one package on demand — the one whose
  class was just jumped to — would cost a fraction of that and answer the rest.
- **The same warm service for the other linters.** ESLint is kept warm and
  answers in milliseconds; `php -l`, `gofmt` and the rest still pay for a
  process each time. They are cheaper processes — a tenth of node's — so it
  has not mattered yet, and PHPStan is where it will.
- **The rest of the checkers.** ESLint, oxlint, `php -l`, SwiftLint and
  `swiftc` are wired; Biome, stylelint, Ruff, RuboCop and `golangci-lint` are
  the same shape of work — a command and a reader for what it prints — and
  each should be added against its real output rather than its documentation.
  PHPStan is worth having and was not wired: it needs the project's own PHP,
  and a machine whose `php` is older than the project's `composer.json` asks
  for cannot run it at all, which is a thing to say out loud rather than fail
  quietly on.
- **Everywhere a name is used, not only where it comes from.** The tags queries
  the jump is built on capture references as well as declarations, so the other
  half — "show me the callers" — is the same index read the other way round.
- **The rest of the previews.** Pictures, PDFs, recordings and Markdown are
  shown; a PDF cannot be searched yet — ⌘F on one searches the project — and a
  preview, like a buffer, does not notice the file changing under it until the
  directory is watched. Mermaid diagrams need a script to
  draw them, and the Markdown page runs none: worth doing only as a picture
  made outside the page.
- **Compiling a grammar query off the main thread.** Colouring a file compiles
  its highlight query the first time that language is opened, and for Swift
  that measures at a second — on the main thread, where it is a second of a
  window that does not move. Every other grammar is a hundredth of that, which
  is why it went unnoticed. The symbol index already compiles its own queries
  in the background and shares them; the colouring should join it. The
  Markdown preview colours fenced code with the same queries, so a README with
  a Swift block in it pays the same second the first time it is shown.
- **The rest of the browser tabs.** One pick at a time, and tabs that do not
  come back once closed. It is worth going further in four places:
  several picks, each with its remark, handed over as one message; the page at
  a phone's or a tablet's width, which the DevTools channel already offers as
  device emulation; agents driving the page themselves — reading it, clicking,
  filling a form — over that same channel; and picking inside an iframe,
  which the picker does not reach. React 19 keeps no file name, so its lines
  are the dev server's and can be off; reading the page's source maps would
  make them exact.
- **Hooks for the other agents.** Claude Code and Codex report their state
  through hooks; Gemini, OpenCode and the rest still go by their titles.
  The two to start from:
  - Gemini's `BeforeAgent` and `AfterAgent`;
  - an OpenCode plugin listening for `session.status` and `permission.asked`.
- **Removing the hooks.** Nothing takes Relay's entry out of an agent's
  settings when Relay goes. The entry is harmless without it, but tidiness
  would be a setting that removes it.
- **Session and project templates.** "New project from template" that creates
  the services and sessions a project always needs.
- **Activity history.** What ran, when, and how it ended.

## Smaller things worth doing

- **An Icon Composer `.icon` bundle.** macOS 26 applies its own glass treatment
  to a legacy `.icns`. It reads well at Dock size, but shipping the new format
  would put the layering under our control rather than the system's.

- **libghostty terminal engine.** Superseded for now: SwiftTerm's own Metal
  renderer is switched on, which is what the CoreText redraw cost was about.
  Worth revisiting only if the renderer itself becomes the limit.
- **Project icons taken from the project.** Rail tiles are initials over a tint
  derived from the path. A project that already carries a favicon or an app icon
  could supply its own, with a way to set one by hand when it does not.
- **Per-project environment variables.** Set once, applied to every session.

---

## Updates

Built. Relay asks GitHub for the newest release on launch and every six hours,
shows a pill in the title bar when one is newer than the running build, and on a
click downloads it, checks it, swaps the bundle and restarts into it. The check
can be turned off in Settings → About, and turning it off stops the request
rather than hiding its result. The request carries a user agent and nothing
else.

How the swap works: an application cannot replace its own bundle while it is
running, so the last step is a short script that waits for Relay to quit, moves
the old bundle aside, moves the new one in and starts it — restoring the old one
if the move fails. Sessions are untouched, because they belong to the daemon.

**What is checked.** Relay is not notarised, so the download cannot be verified
against Apple. What it can do is insist that the new bundle's signature is valid
and that its team identifier matches the copy already running: the difference
between an update to this application and an application somebody else built.

### The caveat that remains

Gatekeeper is a separate problem from update integrity. An app downloaded
through a browser is quarantined, and one that is not notarised shows *"Relay
cannot be opened because the developer cannot be verified"* on first launch —
the user has to right-click → Open once. Only notarisation removes that, and it
needs the $99/year Developer ID. Updates delivered in-app afterwards do not
re-trigger it, because the machine already trusts that copy.

**Worth doing if this ever goes past its author:** a Developer ID certificate,
notarisation in the release step, and a checksum published beside the archive.

### Repository

The GitHub CLI is installed and authenticated as `maketryuk`, so the repository
can be created and the code pushed on request. Nothing has been created or
pushed: that is an outward-facing action and needs an explicit go-ahead.

Suggested shape when the time comes:

- public or private repository named `relay`;
- `master` as the default branch;
- a CI workflow running `swift build` and `swift test` on every push;
- a release workflow triggered by `v*` tags producing the `.app` zip.
