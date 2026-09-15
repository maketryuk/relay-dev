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

- Services: start, stop, restart, logs, port detection, Open URL.
- Ports: every listener on the machine, attributed to Relay's own sessions.
- Docker Compose: up, down, restart, logs, container status, published ports.
- SSH: `~/.ssh/config` with `Include`, connect, pin hosts to a project.
- Notifications for events that need attention, with three levels of opt-out.
- Settings window, rebindable shortcuts, Warp-style tooltips.

277 tests. The daemon suite drives real processes on real PTYs.

---

## Next: v0.2 — Workspaces

The spec's next structural change: `Project → Workspace → Sessions`, where a
workspace is usually a git worktree.

1. **Worktree model.** Create, list and remove worktrees from the app; a
   workspace owns a directory, a branch, its sessions and its services.
2. **Workspace-scoped runtime.** Sessions and services belong to a workspace,
   not directly to the project. The daemon needs a workspace id alongside the
   project id — a protocol change, so it goes in one version bump with anything
   else pending.
3. **Automatic ports.** Two worktrees of the same project must not fight over
   port 3000. Find a free port, start the service on it, remember the binding
   and show it next to the workspace.
4. **Sidebar restructuring.** A workspace switcher above the sessions list.

## Then

- **Richer status adapters.** Per-CLI adapters for Claude and Codex that read
  their specific UI rather than generic prompt patterns.
- **Session and project templates.** "New project from template" that creates
  the services and sessions a project always needs.
- **Diff preview and basic git actions.** Enough to review what an agent did
  without leaving Relay.
- **Activity history.** What ran, when, and how it ended.

## Smaller things worth doing

- **An Icon Composer `.icon` bundle.** macOS 26 applies its own glass treatment
  to a legacy `.icns`. It reads well at Dock size, but shipping the new format
  would put the layering under our control rather than the system's.

- **libghostty terminal engine.** GPU-rasterised text instead of CoreText.
  Contained to `TerminalSurface.swift` by design. Worth doing when heavy
  full-screen redraw starts to matter, not before.
- **Project icons taken from the project.** Rail tiles are initials over a tint
  derived from the path. A project that already carries a favicon or an app icon
  could supply its own, with a way to set one by hand when it does not.
- **Per-project environment variables.** Set once, applied to every session.
- **Proper app signing.** See below — it gates the update mechanism too.

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
- `main` as the default branch;
- a CI workflow running `swift build` and `swift test` on every push;
- a release workflow triggered by `v*` tags producing the `.app` zip.
