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
- Settings window, rebindable shortcuts, Relay's own tooltips.

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

## Auto-update

Planned, not built. The goal: Relay notices a new release, shows a button in the
top-right, and the user updates in one click.

### Distribution without an Apple Developer account

Shipping through GitHub Releases works without paying Apple, with one honest
caveat.

**What works.** Sparkle — the standard macOS update framework — signs updates
with its own EdDSA (ed25519) key pair, generated locally by its `generate_keys`
tool. The public key lives in `Info.plist`, the private key stays out of the
repository. Nothing in that chain involves Apple. The appcast XML and the
`.zip` of each build are ordinary release assets, and `generate_appcast`
produces both. GitHub Actions can build, sign and publish on a tag.

**What does not.** Gatekeeper is a separate problem from update signing. An app
downloaded from the internet is quarantined, and an app that is not notarised by
Apple shows *"Relay cannot be opened because the developer cannot be verified"*
on first launch. The user has to right-click → Open once, or allow it in
System Settings → Privacy & Security. Only notarisation removes that, and
notarisation requires the $99/year Developer ID.

So: free distribution is entirely workable, and the friction is limited to the
very first launch after download. Updates delivered by Sparkle afterwards do not
re-trigger it, because the app is already trusted on that machine.

### Two stages

**Stage A — update notice.** Small and independent of any signing decision.

- On launch and every few hours, GET
  `https://api.github.com/repos/<owner>/relay/releases/latest`.
- Compare `tag_name` against `CFBundleShortVersionString`.
- If newer, show a pill in the top-right: *"0.2.0 available"* with a button that
  opens the release page.
- Respect a "check for updates" setting, off-by-default network access, and no
  telemetry of any kind — the request carries nothing but the user agent.

This is a few hours of work and delivers most of the value.

**Stage B — in-place updates.** Sparkle.

- Add the Sparkle package, generate an EdDSA key pair, put the public key in
  `Info.plist` and the private key in the repository's Actions secrets.
- A release workflow that builds, zips, signs, regenerates `appcast.xml` and
  uploads all three to the release.
- `SUFeedURL` pointing at the appcast asset.
- Replace the pill's "open the page" action with Sparkle's own flow.

### Repository

The GitHub CLI is installed and authenticated as `maketryuk`, so the repository
can be created and the code pushed on request. Nothing has been created or
pushed: that is an outward-facing action and needs an explicit go-ahead.

Suggested shape when the time comes:

- public or private repository named `relay`;
- `main` as the default branch;
- a CI workflow running `swift build` and `swift test` on every push;
- a release workflow triggered by `v*` tags producing the `.app` zip.
