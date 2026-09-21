# Architecture

Decisions taken while implementing milestone 1, and the reasoning behind them.
Everything here is reversible; nothing here is accidental.

## Process model

```
┌──────────────┐   Unix domain socket    ┌──────────────────┐
│  Relay.app   │◄───────────────────────►│   relay-daemon   │
│  (SwiftUI)   │   newline-delimited     │  (own session)   │
│              │   JSON frames           │                  │
│ renderer +   │                         │  PTY master fds  │
│ config store │                         │  child processes │
└──────────────┘                         └──────────────────┘
                                                  │ forkpty
                                          ┌───────┴────────┐
                                          │ zsh / claude / │
                                          │ codex / ssh    │
                                          └────────────────┘
```

The GUI owns configuration and pixels. The daemon owns every process. Quitting
the app is therefore an ordinary window close, not a teardown — which is the
single most important property of the product.

## Why `forkpty` and not `posix_spawn`

The first implementation used `posix_spawn` with `POSIX_SPAWN_SETSID` and file
actions opening the pty slave on fd 0. It spawned processes successfully, and
they were session leaders — but `ps` reported no controlling terminal.

macOS is BSD-derived: a session leader does **not** acquire a controlling
terminal merely by opening one. That requires `ioctl(TIOCSCTTY)` in the child,
which `posix_spawn` file actions cannot express. Without a controlling tty, zsh
starts non-interactive and full-screen CLIs render nothing.

`forkpty` performs `setsid` + `TIOCSCTTY` + `dup2` inside the child, so it is
used instead. The cost is the usual fork-in-a-multithreaded-process hazard: only
async-signal-safe calls are legal between `fork` and `execve`. Every allocation
— argv, envp, paths — therefore happens in the parent (`CStringArray`), and the
child touches nothing but `chdir`, `signal` and `execve`.

## Why a serial queue instead of actors in the daemon

All daemon state lives on one serial `DispatchQueue`. Actors were rejected for a
specific reason: `Task` execution order is unspecified, so routing PTY chunks
through an actor could reorder terminal output. A serial queue gives both mutual
exclusion and strict FIFO delivery, and `DispatchSource` is queue-native anyway.

State-holding classes are `@unchecked Sendable` with the documented invariant
that they are only touched on `DaemonQueue.shared`.

## Why a Unix socket instead of XPC

XPC is the platform-blessed answer and remains the likely endpoint. A UDS was
chosen for milestone 1 because reconnect-to-an-already-running-daemon is trivial
to reason about and debuggable with ordinary tools — the protocol can be driven
from a ten-line Python script, which is how the daemon was tested before any UI
existed.

The choice is contained: `DaemonTransport` is the only protocol that knows bytes
travel over a socket. Replacing it with a Mach service means one new conformance.

## Status detection

No API integration, per the spec. Status is derived from terminal behaviour:

1. output arrives → `working`, reset the quiet timer;
2. quiet for 0.7 s → hand the ANSI-stripped tail to a per-kind `ActivityAdapter`;
3. adapter returns `waitingForUser` / `completed` / `idle`;
4. process exit → `finished` (code 0, or user-requested) or `error`.

Two distinctions matter in practice and are both handled explicitly:

- **A session that has never been typed into cannot be `finished`.** Otherwise a
  `.zshrc` banner on startup reads as completed work.
- **A user-requested `terminate` is not an error.** SIGHUP makes a shell exit
  non-zero; reporting that as a failure would be noise.

`RuntimeStatus` is deliberately decoupled from process liveness: an agent that
reports `finished` after a task is still running and must be able to return to
`working` on the next prompt.

Misclassification is cosmetic by construction — adapters never touch session
behaviour.

## Terminal rendering

SwiftTerm renders; the daemon owns the PTY. `TerminalSurface` is the only file
that knows which emulator is in use, so moving to libghostty later is a
single-file rewrite.

Renderers are cached per session (LRU, 8 entries) so switching sessions preserves
scroll position and cursor state. Evicted sessions detach from the event stream —
their processes keep running, and re-selecting one replays the daemon's
scrollback into a fresh renderer.

Output is coalesced into one feed per runloop turn. A chatty agent emits hundreds
of small chunks per second; feeding each separately makes the renderer, not the
PTY, the bottleneck.

## Persistence

Workspace configuration is a single atomically-written JSON file. SwiftData was
considered and deferred: the persisted set is small, entirely user-owned
configuration, and the daemon — not the store — is the source of truth for
everything that changes at runtime. A plain file keeps the format inspectable and
migratable.

`WorkspaceStore` is the only type that touches disk, so swapping in SQLite or
SwiftData is contained.

It writes to `~/.relay` — `~/.relay-dev` for the development build — rather than
to Application Support. What is in there is not the opaque state of a
document-based app: a workspace file worth reading when something looks wrong, a
daemon log worth tailing, and a scratch directory an agent writes files into.
All three are reached from a terminal, and `~/Library/Application Support/Relay
Dev` is a path nobody types twice.

An install written by an earlier build is moved by
`RelayPaths.migrateSupportDirectory`, called once by whichever of the app and
the daemon starts first — the daemon outlives the GUI, so it is regularly the
new build's first process to touch the directory. It moves file by file rather
than the directory in one go, because the destination existing says nothing
about whether anything is in it: the daemon creates it when it opens its log,
and `swift test` creates it through the workspace store. A whole-directory move
gave up in both cases and left an empty workspace beside a full one. Anything
already at the destination is never overwritten, and the old directory is
removed only once it is empty.

## The chat is a project

Some questions have nothing to do with any codebase, and answering them used to
mean leaving Relay or adopting a directory as a project to hold a conversation
that was never about it. The rail therefore opens with a chat: sessions started
in it run in `~/.relay/chat`, which is created the first time one is started and
not before.

It is a `Project` — `Project.chat`, with the fixed identifier `relay.chat` —
because everything a session needs is keyed by one: the pane layout, the
last-selected session, the row order, the history. A nullable project identifier
would have put a `nil` branch through all of it to save a directory that has to
exist anyway, since the agent has to be started somewhere.

It is never in `projects`, so it cannot be removed, reordered, renamed or
configured, and nothing about it reaches the workspace file except the sessions
that happen to be in it. The right-hand panel offers it one tab, its
conversations: a directory with no repository, no services and no containers
would otherwise show four tabs that are permanently empty.

## Idle cost

- The classification timer only runs while at least one session is alive.
- Git state is polled every 12 s for the visible project only, one `git status
  --porcelain=v2 --branch` call that yields branch, dirtiness and ahead/behind
  together.
- Terminal output is only streamed to clients that explicitly attached, so a
  background session costs a hidden window nothing.
- Project status is computed from session snapshots already in memory — never
  from a process scan.

---

# Milestone 2

## Services are sessions

A service is a daemon session tagged `role: .service(id:)`. It shares the PTY,
the scrollback, the status detection and the reconnect path with every other
terminal, and differs only in how the UI presents it.

The alternative — a separate non-interactive runtime with its own log buffer —
was rejected. A dev server whose output cannot be scrolled, searched or
interrupted is a downgrade from running it in a terminal, and it would have
duplicated the one piece of machinery that already works.

Tagging with the definition's id, rather than remembering a session id in the
GUI, is what lets a relaunched app reconnect a running server to its sidebar row:
the daemon is still the source of truth, and the tag travels with it.

## Protocol versioning is not ceremony here

Most apps can treat a version field as boilerplate. Relay cannot: the daemon
deliberately outlives the GUI, so a freshly built app routinely meets a daemon
from the previous build.

Milestone 2 added message cases and a field, so the version went to 2. On a
mismatch the client sends `shutdownDaemon` — a case that predates the bump, and
therefore still decodable by the old daemon — waits for the socket to close, and
relaunches. `Tests/RelayProtocolTests/WireCompatibilityTests.swift` pins the
encoding of the messages this path depends on, so a change that would strand a
user's running sessions fails the build instead.

The cost is honest: retiring the old daemon kills whatever it was supervising.
There is no way around that, because those processes are only reachable through a
protocol this client no longer speaks.

## Ports and Docker live in the daemon

Both are discovery, which the spec assigns to the daemon, and both need process
ownership the GUI does not have. Keeping them there also means one
implementation rather than two.

Port discovery walks the process tree because the process Relay spawned is almost
never the one that binds: `npm run dev` forks a package manager, which forks the
real server. `ps` gives the tree, `lsof` gives the listeners, and the daemon maps
each port back to the session whose subtree owns it so the UI can say "Dev"
instead of "node".

Results are cached for a couple of seconds. Every scan is two process spawns, so
polling was never an option; the popover asks when it opens, and a freshly
started service triggers a short burst of retries while it binds.

## Shelling out needs exit status, not just stdout

The first `CommandRunner` returned stdout only. That is enough for `ps` and
`lsof` and wrong for `docker`, which reports why it failed on stderr while
printing nothing at all on stdout — so an unreachable engine was indistinguishable
from a project with no containers, and the sidebar cheerfully claimed Docker was
available while it was down.

`CommandResult` now carries status, stdout, stderr and a timeout flag, and each
caller interprets them: `lsof` exits non-zero when it merely matched nothing, so
its status is ignored; `docker` failing with "no configuration file provided"
means the engine is fine and this project simply has no stack, which must not be
reported as an outage.

Both pipes are drained concurrently, because a child that fills one while the
reader blocks on the other deadlocks.

## Descriptor hygiene

`forkpty` hands the child a copy of the parent's descriptor table, and only
descriptors marked `FD_CLOEXEC` disappear at `execve`. The switch away from
`posix_spawn` silently gave up `POSIX_SPAWN_CLOEXEC_DEFAULT`, and every spawned
agent was inheriting the daemon's log handle and its live IPC sockets — visible
in `lsof` on a hung child.

The child now closes everything above the pty, and the daemon marks its own
descriptors close-on-exec as well. `DescriptorInheritanceTests` proves it by
having the child try to write through the number rather than by counting
descriptors, which is ambiguous across processes.

## Notification policy is separated from delivery

`NotificationPolicy` is pure and exhaustively tested; `AttentionNotifier` does
nothing but hand an already-decided event to `UNUserNotificationCenter`. The
policy is the part that becomes intolerable when it is wrong, and it encodes two
judgements worth stating:

- a shell returning to its prompt is not an achievement, so only agents and
  services announce completion, and only after actually working;
- the session on screen in an active window never notifies.

## What the tests are for

Real behaviour is tested against the real thing wherever that is possible: the
daemon suite starts an actual daemon on a throwaway socket and drives actual
processes in actual PTYs. Parsers are pure functions tested against captured
fixtures. Mocks appear only where the alternative would be to depend on the
developer's own `~/.ssh` or a running Docker engine.

That choice has already paid for itself. Tests, not manual use, caught the
`posix_spawn` controlling-terminal defect, the SIGHUP disposition that made
Terminate silently do nothing, the chunk-boundary dependence that made status
classification non-deterministic, and the descriptor leak above.

---

# Notes on two questions worth recording

## Terminal rendering is CPU-rasterised today

SwiftTerm ships a Metal renderer, but only for iOS: `iOSTerminalView` can swap
in an `MTKView`, while `MacTerminalView` draws glyphs with CoreText into a
`CGContext` on a layer-backed `NSView`. So on macOS the rasterisation is on the
CPU and only compositing is on the GPU — the same arrangement Terminal.app uses.

At Relay's scale this is not currently the bottleneck, and the design already
avoids the cases where it would be: only the visible session renders, output is
coalesced into one feed per runloop turn rather than one per PTY chunk, and
renderers for sessions the user has not looked at recently are released.

Where it would start to show is sustained full-screen redraw — a fast TUI, a
runaway `yes`, flinging through a large scrollback. The answer there is not to
optimise CoreText but to change the engine, which is why `TerminalSurface` is
the only file that knows which emulator is in use. libghostty is the intended
replacement and is GPU-rasterised; swapping it in is a one-file rewrite by
construction.

## Keyboard shortcuts are data, not code

Bindings live in `ShortcutSettings` and resolve through `ShortcutResolver`; the
menu builds itself from whatever the user has configured. Two decisions are
worth stating:

- Only *differences* from the defaults are persisted, so changing a default
  later still reaches everyone who never touched that command. Rebinding back to
  the default deletes the override rather than freezing today's value.
- Conflicts are reported, never prevented. Refusing a keystroke the user
  deliberately chose is worse than showing them what it collides with.

`⌘,` is taken over from SwiftUI's Settings scene deliberately: leaving the
system's menu item in place would mean the shortcut editor lists a binding it
cannot actually change.

---

# The daemon outliving the GUI cuts both ways

The daemon surviving app restarts is the product's central promise, and it is
also its sharpest edge: a rebuilt app routinely meets the *previous* build's
daemon, still running, still behaving exactly as it did before.

This was caught the way such things usually are — a fix that plainly worked in
tests did nothing in the running app. The machine-wide port scan returned zero
ports because the daemon answering had been started nine hours earlier, before
the scan was rewritten. Nothing was wrong with the code; the code simply was not
the code that was running.

Protocol versioning only catches the subset of changes that alter the wire
format. Most daemon changes — a new heuristic, a fixed scan, a different
timeout — leave the protocol untouched and would be invisible.

So the daemon now reports a `buildIdentity`: a short SHA-256 of its own
executable, sent in the handshake. The GUI hashes the daemon binary it ships
with and compares. If they differ, the running daemon is retired and a fresh one
launched from the app bundle.

Hashing contents rather than paths or timestamps matters: installing the app to
`/Applications` copies the binary and resets its modification time, and an
identical daemon at a new path must not look like a different build.

The cost is stated plainly, because it is real: retiring a daemon kills the
sessions it was supervising. An app update therefore ends running agents. That
is unavoidable — those processes are only reachable through the daemon being
replaced — and it is far better than the alternative of silently running stale
code.

The same investigation exposed a second gap: `DaemonClient` had no request
timeout, so a frame the daemon could not decode would leave the UI waiting
forever. Requests now fail after twenty seconds.

# Sessions name themselves

Naming sessions "Claude 2", "Claude 3" tells the user nothing. Naming them after
what they are doing requires knowing what they are doing — and the terminal
already carries that, because programs announce it through `OSC 0/1/2`, the same
sequence that titles a tab in every other terminal. Claude Code, Codex and most
shells set it without being asked.

`TerminalTitleParser` reads it incrementally, because a PTY splits output
wherever it likes and a title routinely straddles two reads. The parsed title
becomes the session's display name unless the user has renamed it by hand, at
which point their choice wins permanently.

No model is consulted and no network call is made. The information was already
in the byte stream.

# Presets, not a settings toggle

"Start Claude" is not one action. Starting it with approvals on and starting it
in automatic mode are different enough to deserve separate rows, and each CLI
spells its automatic mode differently — `claude --permission-mode auto`,
`codex --approve-for-me`, `gemini --approval-mode auto_edit`. That is exactly
the sort of thing nobody should be typing from memory.

So the new-session menu lists presets: a name, an agent mark, and the command
the preset will actually run, shown underneath so it is never a guess. Agents
default to their automatic variant with the supervised one directly beneath,
because handing an agent unattended write access should stay one click away in
both directions.

Built-in presets live in code rather than in the workspace file, so a corrected
flag reaches existing users instead of being frozen at whatever shipped first.
Only user-defined presets are persisted.
