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

An agent's status is what the agent says it is. Only when it says nothing is it
read off the terminal. `AgentStatusTracker` takes the first answer it has, in
this order:

1. **The agent's hooks.** Claude Code and Codex run a command at every prompt,
   tool call, permission prompt and end of turn, and describe the event on its
   stdin.
   - The command is `relay-hook`, installed into `~/.claude/settings.json` and
     `~/.codex/hooks.json` (see below).
   - It sends the event's name, its tool and its tool-call id to the daemon —
     and, for the subagents an agent starts, where each works and what it was
     asked to do — as one JSON line over `/tmp/relay-<uid>-hooks.sock`, which
     sits beside the daemon's own socket.
   - Mapping:
     - `UserPromptSubmit`, `PreToolUse` and `PostToolUse` → `working`;
     - `PermissionRequest`, or a question tool (`AskUserQuestion`,
       `request_user_input`) → `waiting`;
     - `Stop` → `finished`, unless a subagent it started is still running in
       the background (see "Subagents are listed where they work");
     - `SessionStart` from a start, a resume or a `/clear` → `idle`.
   - A permission wait holds until the call it is about runs — the id comes from
     the `PreToolUse` before it, because Claude leaves it off the request — since
     tools running beside it keep reporting.
   - A hook is believed for 30 minutes.
2. **The agent's title.**
   - Claude Code puts `✳` in front of its title when it waits for a prompt, and
     a spinner frame — Braille, or `◐◓◑◒` — while it works. Codex draws a Braille
     spinner. Gemini has a glyph for each state.
   - A spinner that has not moved for 3 s has stopped.
   - `✳` coming back after work is a finished turn.
   - `✳` held for 1.5 s after the last hook said `working` is a cancelled one,
     because no hook fires when the person cancels.
3. **The terminal's behaviour**, for everything else — shells, and agents that
   say nothing at all:
   1. output arrives → reset the quiet timer;
   2. quiet for 0.7 s → hand the ANSI-stripped tail to a per-kind
      `ActivityAdapter`;
   3. the adapter returns `waitingForUser` / `completed` / `idle`.

Process exit is `finished` (code 0, or user-requested) or `error`, whatever came
before it.

The terminal's behaviour was once the only source, and its failures are why it
is now the last:
- The tail is the raw stream with its escapes removed, not the screen. An agent
  that redraws in place leaves every recent frame in it, so an old
  `esc to interrupt` kept a finished agent working.
- A line of prose that asked a question made one "wait".

What the terminal is still trusted with has rules of its own:

- **A key is not a command; a submitted line is.** Output within 0.25 s of a
  key that edits a line is its echo or its input box redrawing, and is not
  counted as work. Before this, typing a question into an agent made it
  "Working" and then "Finished" before it was sent.
- **A session that has never been sent a line cannot be `finished`.**
  Otherwise a `.zshrc` banner on startup reads as completed work.
- **A user-requested `terminate` is not an error.** SIGHUP makes a shell exit
  non-zero; reporting that as a failure would be noise.

**The hooks are installed globally and do nothing outside Relay.**
- The entry names no path. It runs `$RELAY_HOOK` if that is set, and otherwise
  drains stdin — and for Claude prints `{}`, since Claude reads a permission hook
  that says nothing as one that refused.
- Only a terminal Relay started has `RELAY_HOOK`, `RELAY_HOOK_SOCKET` and
  `RELAY_SESSION_ID`, so the same entry is right for every terminal on the
  machine, every build and both flavours. Other tools install theirs the
  same way, beside it.
- The app checks the entry at every launch and writes only when it is missing
  or out of date. `OrderedJSON` keeps the rest of the file as it was: key order,
  number spelling, the lot.
- Codex also needs a trust record in `config.toml`: the `sha256` of the entry's
  canonical JSON, keyed by the file, the event and the entry's position. It is
  the same hash Codex computes itself. A config that defines hooks in a
  form a new table could clash with is left alone, and Codex asks about the hook
  itself.

**An agent can start another.** `claude -p` from a shell tool inherits the
terminal and its environment, and its `Stop` would end the outer turn. The helper
sends the processes above it. The daemon accepts an event only if the session's
own process is reached through at most one agent.

**When a shell session's agent quits**, the terminal's foreground process group
becomes the shell's again. That clears what the agent last said, which would
otherwise outlive it.

**Only agents are marked.** A plain terminal still has a status, which the
Services panel and notifications read. But it has no mark in the sidebar or the
pane header, and no say in the project's tile: a terminal printing is what a
terminal does, not news.

A shell session in which an agent has announced itself, through a hook or its
title, is `hostsAgent` in its snapshot and is marked while the agent runs. The
field is decoded leniently, so a daemon that predates it reads as "no agent in
the shell".

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

A saved arrangement this build cannot read — one naming a kind of pane it does
not know, which is what an older build finds after a newer one — is dropped on
its own. It used to fail the whole workspace file, which the store then put in
quarantine, projects and all.

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
  together, and one `git worktree list`. The other worktrees' statuses are read
  on the same tick, and only once there is more than one. How many lines
  changed is a `git diff --shortstat` of its own, asked only of a worktree
  that has changes.
- Terminal output is only streamed to clients that explicitly attached, so a
  background session costs a hidden window nothing.
- Output is not news in itself. A chunk that changes a session's title, or
  shows an agent in it, sends its snapshot at once; one that only moves its
  last-activity time waits for the tick, and is sent at most every two
  seconds. A snapshot went to every client with every chunk — a kilobyte, on
  macOS — and each one redrew the window's session lists.
- The classifier strips escapes from a session's recent output only when
  output has arrived since it last did.
- Project status is computed from session snapshots already in memory — never
  from a process scan.
- The History tab's transcripts are parsed again only once they have been
  written to: `TranscriptReadings` keeps what each one said, by its size and
  modification date. Thirty of them parsed every ten seconds were a fifth of a
  second of CPU each time.
- The status bar's CPU and memory are read with syscalls, never a fork: every
  5 s while the bar shows, every 2 s while its popover is open, and not at all
  while the window is hidden.

## Input waits for the terminal

A terminal takes a couple of kilobytes of input for a program that is not
reading and refuses the rest until it does. The rest used to be retried in a
loop on the daemon's queue, so a paste into a busy terminal froze every other
one for as long as the program did not read — and for good when it echoes what
it reads, like `cat` or a REPL, because its echo waited for that same queue to
read it, and so did the reap of a program that had exited. What the terminal
refuses now waits in `PTYProcess` and goes out from a write source when there
is room, on the queue the output is read on, so keystrokes keep their order.

## Buffers trimmed at the front let go

`Data.removeFirst` does not free what it removes: it moves where the bytes
start, and the storage behind them keeps everything before. The scrollback,
the tail the classifier reads and the queue of writes to each client were all
trimmed that way, so the daemon held every byte a session had printed — four
megabytes printed was twenty held — while each buffer's count said it was
within its cap. `discardFirst` drops the front the same way and copies what is
left into storage of its own once the dropped part outweighs it.

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

## CPU and memory are measured in the window

The status bar's figures look like a cousin of the ports window and are the
opposite decision. Ports need `lsof` and the whole process table. CPU and
memory need the process each session started, which the window already has
from its snapshots, and two `libproc` calls per process, which any process of
the same user may make. So nothing crosses the socket, the protocol does not
change, and a daemon inherited from the previous build is measured the same as
a new one. The daemon's own process is asked of the socket (`LOCAL_PEERPID`),
since with no session open there is no parent to infer it from.

A session is its whole tree, walked with `proc_listchildpids` from the process
the daemon forked. Memory is `ri_phys_footprint`, which is what Activity
Monitor shows; resident size counts a shared library once for every process
that maps it, and summed over a tree of node processes gives a number nobody
recognises.

CPU is the difference between two readings, and each reading adds up every
member's own time and its `ri_child_*` — the time of every child it has
reaped. That is what makes a tree measurable by its living members: a compiler
that ran between two readings is gone from the table, and its time is on the
`make` that waited for it. Two things break the sum, and both are dropped with
the previous figure kept: a total that goes down, because a process was
reparented out of the tree or an `exec` started its count again, and one that
goes up by more than every core could have spent, because a process joined
carrying its whole lifetime. `rusage_info` counts in Mach ticks — nanoseconds
on Intel, 125/3 of one on Apple silicon — which is converted once.

Relay's own share is the window's tree and the daemon's, less the sessions
hanging from the daemon, and with the daemon's reaped time left out: that is
every session that has ended, and counting it made closing a terminal look
like Relay spending the terminal's lifetime in a moment. Docker containers run
in Docker's virtual machine and appear nowhere, which the popover says rather
than leaving a compose session looking cheap.

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

# Relay leaves App Translocation before it starts the daemon

The daemon outlives the app only as long as the file it runs from does. macOS
runs a quarantined app that Finder never moved from a read-only copy under
`AppTranslocation`, and removes that copy when it decides to: once, `lsd`
removed it 14 ms after a volume of Software Update's was unmounted, with the app
open. Every process whose code was paged in from the copy then died of SIGBUS
in the same millisecond, *"object has no pager because the backing vnode was
force unmounted"*, and the daemon ships in the same bundle, so it was one of
them, and every terminal went with it. A daemon started from a mounted disk
image is exposed the same way when the image is ejected.

So `RelayApplication.main()` asks where it is running before anything else:
before the workspace is read and before a daemon is looked for, so a
translocated launch never starts one. `Translocation` then leaves the copy in
one of two ways:

- **In place**, when the quarantine flag can be cleared from the original —
  the usual case, an app in `/Applications` or `~/Downloads`. Once the flag is
  gone macOS runs the bundle where it lies, which is what a move in Finder
  would have achieved. The copy starts the original once its own process has
  gone, since while it runs `open` may bring it forward instead.
- **By copying into Applications**, when the original cannot be changed: a
  disk image. The copy replaces an earlier Relay there, and refuses anything
  else that has the name.

The reopened copy carries an argument that stops it trying the same thing
twice. Without it, a macOS that translocated for some other reason than the
flag would be reopened in a loop; with it, the person is asked.

Whether a path is translocated, and from where, is answered by
`SecTranslocateIsTranslocatedURL` and `SecTranslocateCreateOriginalPathForURL`,
which Security exports without a public header. They have kept their
signatures since macOS 10.12, and Sparkle and LetsMove use them. They are
looked up with `dlsym`, so a macOS that drops them runs Relay as before rather
than failing to load it. The flag is only removed from Relay's own bundle, and
only after Gatekeeper has let that bundle run.

The file operations are tested against real bundles and extended attributes.
The translocated launch is not: macOS creates a translocation only for
LaunchServices, and refuses `SecTranslocateCreateSecureDirectoryForURL` to
anything else, so no test can make one.

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

# Where the usage figures come from

The bar along the bottom shows how much of each agent's rate limits is spent.
Both agents know the answer, and neither writes it down the way a reader would
want.

**Codex writes every reading it is given.** A `rate_limits` record goes into the
session's rollout log whenever the figure changes, so the newest such record
anywhere on disk is what the CLI itself would show. `CodexUsageReader` compares
the time on the records rather than on the files holding them: resuming a
conversation appends to the log it started in, so the most recently written file
is routinely an old one whose limits are months out of date, and a session
opened a moment ago carries no record at all. The walk stops as soon as no
unread log can hold a newer record, which is usually after the first.

**Claude does not.** The figures in its status line come from the headers of
every answer it gets and stay in the process. `~/.claude.json` holds a copy, but
the CLI only rewrites it when it asks Anthropic for the figure on purpose —
rarely enough that a cache days old is the normal case, not the exception. A
client that reads only that file shows a number that was true once, which is
indistinguishable from a number that is true now.

So Relay asks the same endpoint the CLI does, with the token the CLI already
holds — the keychain item Claude Code writes, which macOS gates behind its own
permission sheet the first time. This is a deliberate reversal of an earlier
rule that Relay would read files and never make a request: the rule produced a
bar that was quietly wrong, and being wrong about a limit is worse than asking.
Nothing is done with the token but read this account's own usage; it is never
stored, logged, or sent anywhere else.

The endpoint is not generous, so it is asked at most every five minutes, never
while a `Retry-After` is in force, and a refusal that names no time backs off
anyway. Between polls the last answer stands, and when there is no token or no
answer at all the cache on disk stands in — minus any window whose reset has
already passed, because a five-hour bar from a window that ended two days ago
describes nothing.

# Files that are not text

A picture, a PDF or a recording opens in the same pane a file does, under the
same one-at-a-time rule, and is a `FilePreview` rather than an `OpenFile`.
Everything that holds an `OpenFile` — saving on losing focus, the checker, find,
⌘-click — is asking for text, and a buffer full of a PNG's bytes would answer
each of them wrongly instead of not at all. `FileEditors` holds both, so the
layout, ⌘W and a relaunch treat them alike.

**What counts as a preview is a list of extensions, not the system's type
tree.** macOS knows `.ts` as an MPEG transport stream and `.mts` as a
camcorder's, so asking `UTType` whether a file is a video would open every
TypeScript module in a player. SVG is left to the editor: it is a picture, but
in a project it is almost always opened to be changed.

**Markdown is rendered by cmark-gfm into a web view that runs nothing.**
cmark-gfm is what GitHub renders with, so a README reads the way it will there;
a web view because what Markdown becomes is HTML, and every native way of
drawing HTML is a web view with fewer features. Raw HTML is let through — a
README's centred logo and its badges are raw HTML — so the page is fenced in
three times over: GitHub's `tagfilter` escapes `script`, `iframe` and the rest,
the web view has JavaScript switched off, and the page's own
Content-Security-Policy allows images from disk and HTTPS and nothing else. The
only script that runs is Relay's, in a content world of its own, and all it
does is read and restore the scroll position across a re-render.

The page is given an address under Relay's own `relay-file:` scheme rather than
a `file:` one, because a web view handed HTML as a string will not read `file:`
at all. A relative `docs/shot.png` then resolves beside the document the way it
does on disk, and Relay answers the request — synchronously, and only for a
file small enough for that to stay true, because answering a request the web
view has since cancelled is an exception rather than an error.

# Worktrees are git's, and a session is in one by where it started

Two agents in one checkout edit the same files, commit each other's changes and
leave a diff nobody can review as one piece of work; switching branches moves
the files under every session at once. A worktree gives each piece of work a
folder and a branch of its own, sharing the repository's history, and costs a
few seconds rather than a clone.

**Nothing git knows about a worktree is stored.** The list is `git worktree
list`, read on the same 12-second tick as the branch. A record of Relay's own
would disagree with git the moment anyone typed `git worktree add` — and agents
do: Claude Code and Codex both have a `--worktree` flag. One fact git could not
otherwise answer, whether Relay made a branch and may therefore delete it, is
kept in the repository as `branch.<name>.relayCreated`, which git forgets along
with the branch.

**What has been said about a worktree is the other thing git cannot answer.**
A status — to do, in progress, in review, completed — and a comment, set from
the heading's menu or by an agent through `relay`, are kept in the workspace
file as `worktreeNotes`, filed by project and then by the path git reports.
By project, because the only thing that says a worktree has gone is its
repository's list, and a list speaks for one repository: each fresh list lets
go of the notes of the worktrees it no longer names. Keyed by path alone, a
worktree removed while Relay was closed would never be seen to go, and its note
would turn up on the next worktree made in that folder — which, for the same
branch, is the same folder. A list that could not be read lets go of nothing,
and neither does an empty one, which git never gives for a repository: what
people wrote cannot be read back from anywhere once it is dropped. A path no
project's list names is not noted at all, since nothing would show the note and
nothing would ever take it away. On the heading the status is a disc filling up
inside a ring beside the name — a family of shapes apart from the agents'
spinner, question, check and dot, in their colours for the same meanings — and
the comment is a second line under it.

**Sessions were not given a worktree identifier.** The plan was a workspace id
beside the project id in the daemon, which is a protocol change and a retired
daemon for everyone updating. It turned out not to be needed: every session
already carries the directory it was started in, and the deepest worktree
containing that directory is the one it belongs to. Deepest, because Claude
Code keeps its worktrees inside the checkout they came from. The cost is that a
session is placed by where it started, not where it is now: `claude --worktree`
launched from the project's folder moves into a worktree of its own and stays
grouped under the folder it left.

**Git spells a worktree's path with its symlinks followed**, `/private/var` and
not `/var`, and a project added through a link starts its sessions at the
linked spelling. A directory that matches no worktree as it is written is
resolved with `realpath` and tried again — not `URL.resolvingSymlinksInPath`,
which strips `/private` back off. Only the unmatched ones pay for the look at the
disk, and a session that matches nothing is listed with the project's own
checkout rather than dropped: a hidden row would be a running process with no
way back to it.

**Until git has answered once, the sidebar shows a spinner, not the sessions.**
Before the first list there is no telling one list from several groups, and
drawing the flat list and then regrouping it moved every row under the pointer
at each launch. The wait is kept short by adopting the list as soon as it
arrives: the other worktrees' statuses, a `git status` each, follow in a second
step, so a project with a dozen worktrees is grouped after one call rather than
thirteen. A list git could not give still ends the wait.

**Everything the right-hand panel reads is keyed by project and means "the
worktree being looked at".** That worktree follows the selected session, and
changing it throws away what was read from the previous one — the changes, the
diffs, the TODO list, the branches — before reading again, so the panel never
shows one checkout's files under another's name. Each asynchronous read checks
on arrival that it is still about the worktree that is open. Keying every cache
by worktree instead would have touched every one of them to buy the ability to
show two worktrees' panels at once, which nothing on screen does. What is kept
by folder — the file list, the symbol index, a warm ESLint — goes when git
stops listing the worktree.

**They live in `~/.relay/worktrees/<repository>/<branch>`.** Outside the
repository, because the file tree, search, the TODO scanner and the symbol index
all walk the project's folder and would otherwise find a second copy of it;
under Relay's own directory rather than beside the repository, so a folder of
projects does not fill up with siblings. The development build uses
`~/.relay-dev`, like everything else of its own.

**A branch goes with its worktree when git proves nothing on it would be
lost**, and only a branch Relay made. `git branch -d` is asked first, since it
is the rule people know, but on its own it asks the wrong question twice. It
measures against HEAD, and the main checkout's `main` is behind `origin/main`
until somebody pulls, so a branch merged on the forge was kept for as long as
nobody did. And it asks whether the branch's commits are there, which after a
squash or a rebase merge they never are: the forge wrote commits of its own.
When `-d` refuses, `GitBranchIntegration` measures the branch against the
remote's default branch — `origin/HEAD`, then `main` or `master` on the remote,
then locally — and answers only with a proof: the branch is an ancestor of it;
merging the branch in with `git merge-tree --write-tree` would leave its tree
as it is; or one commit on it since the fork changes exactly the branch's files
and is what merging the branch into that commit's parent gives, which is how a
forge makes a squash. The last is what survives the base writing next to the
squashed lines afterwards, as every pull request adding a changelog line does
to the one before it. `git cherry` was the other candidate and is not used: it
matches commit by commit, which a squash never does, and its patch ids ignore
whitespace, which is right for a rebase deciding what to skip and wrong for a
proof that decides what to delete. When the local copy of the base proves
nothing, that one branch is fetched and the branch asked about again, because
removing a worktree is what usually follows merging its pull request, and the
merge is on the forge until something fetches it. The delete is
`update-ref -d` with the commit that was judged — git's compare-and-delete —
so a commit an agent makes between the check and the delete keeps the branch;
its config section goes with it, as `branch -D` would take it, and a branch
another worktree has checked out is left alone, since `update-ref` does not
know that worktrees exist. A git older than 2.38 cannot merge without a
working tree, proves nothing, and keeps the branch. A kept branch is reported
with the commit it was judged at, and the toast's Delete Branch is held to that
commit the same way: what the person agrees to lose is what they were told
about, and a commit that landed after the toast appeared keeps the branch.

**From the sidebar, the branch is judged before the question is asked.** A
worktree whose branch was going to stay used to vanish on Remove and say so
afterwards, in a toast, which is the wrong order for the one outcome worth
stopping for. `forecastBranch` asks the same things while the worktree is still
there — `-d` would refuse a branch that is checked out, so what it would accept,
every commit already in the main checkout's `HEAD`, is asked directly — and the
question is put only once it has answered: that the branch goes with it, that
it stays and how many of its commits `git cherry` finds nowhere in the base, that
it is somebody else's, or how many commits a detached `HEAD` would lose. The
heading shows a spinner meanwhile, since the answer can include fetching the
base. Removing then does what the question said: a branch that was to go goes
only while it points where it was judged, and one that was to stay is not
judged again, because the person agreed to lose the folder on the
understanding that the branch stays. The cleanup window and `relay worktree rm`
judge afterwards, as before; the window lists the branches that will stay in
its own question.

**Cleaning up is a list with reasons on it, never a sweep.** Clean Up
Worktrees… lists every worktree `canRemoveWorktree` allows, reads each one off
the main thread — uncommitted files, commits no remote has, whether its branch
is in the default base, when it was last touched — and removes only what was
ticked and on screen when Remove was pressed. The decisions are one pure type,
`WorktreeCleanup`, tested on made-up facts; the reading is
`WorktreeFactsReader`, tested against real repositories. A row cannot be ticked
while it is being read, git cannot read it, it is locked, an agent in it is
working or waiting, a detached `HEAD` in it has commits nothing else reaches, or
it has uncommitted files the person has not agreed to lose. That agreement is
for a number of files and lapses when the number changes. Commits that are only
on the worktree's branch warn and do not block: removing a worktree deletes its
folder, and the branch stays unless Relay made it and git proves its work is
already in the base, so the work is still there afterwards. What is ticked before anyone ticks anything
is merged, clean, has nothing running and has been left alone for a day — the
day because a branch started a minute ago from the base is also, trivially,
merged. Pinned and archived worktrees, a row dismissed until it changes,
remote hosts, and a pull request or ticket per worktree would each be a reason
to keep or to tick a row; Relay has none of them yet, so neither does the
window.

**Last activity is the newest thing that only moves when somebody does
something**: when `HEAD` last moved in the worktree (its reflog, which also
dates its creation), its commit's date, the newest uncommitted file, and the
newest output from a session in it. The index is left out because `git status`
rewrites it, and Relay runs that on every worktree every few seconds; the
folder's own date, because Finder and Spotlight change it. The reader's own
`git status` passes `--no-optional-locks` for the same reason.

**Removal is one worktree at a time, each read again just before it goes**,
through the same `performWorktreeRemoval` the sidebar uses, which says what
happened and shows nothing. Each settles its branch in the repository they
share, and something may have started in a worktree since its row was drawn. A
refusal is written on its row in git's words and the rest carry on; one toast
at the end says how many went, which branches were kept and what failed. The
window's state lives on the model, so a removal outlives the window being
closed, and opening it again shows how far it has got.

What is not done yet — getting a fresh worktree ready to run, services and ports
per worktree, the rest of finishing a piece of work — is in `ROADMAP.md`.

# Subagents are listed where they work

An agent that starts subagents is doing several things at once, and the
sidebar showed one of them. A worktree Claude Code had made for one of its
subagents sat under its heading with nothing in it while an agent was busy
there. Each subagent is now a line: under the session that started it, or under
the worktree it works in when that is another one — what it was asked to do,
what kind of agent it is, and the mark a session would wear for its state. It
is not a terminal. Nothing can be typed to it, and a click on it goes to the
session that started it.

**Everything comes from Claude Code's hooks.** `SubagentStart` and
`SubagentStop` bracket each one, every event fired inside one carries its
`agent_id`, its `agent_type` and its `cwd`, and the installer now asks for
those two events and for `SessionEnd`. The daemon keeps the list, in
`SubagentRoster`, beside the tracker that already read those events for their
waits; the app only draws it.

**What a subagent was asked to do is in none of its own events.** It is in the
parent's call to the `Agent` tool — `tool_input.description` — and that call
does not say which agent it made until it returns. Captured from Claude Code
2.1.280 rather than taken from the documentation, which names no link at all
(`Tests/RelayDaemonCoreTests/ClaudeSubagentCaptures.swift` holds the runs): a
background call returns the moment its agent starts, with the agent's id in
`tool_response.agentId`; a foreground one returns only after its agent has
stopped. So a line's task comes from whichever of these says so first:

- the call's answer, which is exact and, for a background agent, arrives with
  the agent's own first event and sometimes ahead of it;
- the note Claude Code writes beside the transcript on each subagent,
  `subagents/agent-<id>.meta.json`, which names the call and the task. It is
  written a few milliseconds after `SubagentStart`, so the helper looks for it
  on every event of a subagent's and finds it from the first tool call on. It
  is undocumented; a note that goes missing or changes shape costs the task's
  words, never the line;
- `background_tasks` on `Stop` and `SubagentStop`, which lists each background
  agent with its task;
- elimination, at the moment the agent starts: if exactly one call of its type
  is still waiting for an agent, it is that one's. A call's `PreToolUse` hook
  has finished before its agent starts, so its own call is always among those
  waiting — and so is every other call of that type made in the same message,
  which is why two of a type started together are never guessed between. They
  read as their type until one of the above names them, and anything that does
  replaces a guess, so a guess thrown by two hooks arriving out of order is
  taken back rather than kept. Ordering alone was the other candidate, and is
  what this refuses to rely on: the daemon reads each hook on a connection of
  its own, concurrently, and a parallel call's hooks can interleave with its
  neighbour's.

**A subagent is placed by the rule a session is**, on its own `cwd`: the deepest
worktree holding it, retried through `realpath`. Claude Code keeps `cwd` where
the agent is. A subagent started with `isolation: "worktree"` works in
`.claude/worktrees/agent-<id>`, which git lists, so it gets that worktree's
heading; one started without it has its parent's `cwd` even after `cd` in a
command, because Claude Code puts the shell back. The same worktree as its
session puts the line under the session, dragged with it; another puts it after
that worktree's sessions, with its session's name, and counts it as an agent at
work there — the folded heading's mark and Clean Up Worktrees… both see it. A
subagent that has not said where it is, or is where no worktree is, stays with
its session, for the reason a stray session stays with the project's checkout.

**How long a line lasts.** It appears on `SubagentStart`, or on the first event
that names the agent when that was missed. It works, waits for a permission or
a question as a session does, and is finished on `SubagentStop`. A finished line
stays two minutes — seen on a glance back, gone before the sidebar is a
history. A foreground subagent cannot outlive its parent's turn, so the turn's
`Stop`, or the parent going idle, which is how a cancel shows, ends whatever of
it is still marked working; a background agent that nothing had said was one
is ended with them, and its next event brings it back. A line that has heard
nothing for thirty minutes goes: the tracker's own measure of a hook worth
believing, since a background agent can sit through a long build without a word
and a short timeout would take working agents off the list. One that is
waiting does not go, because a question is answered or it is not. The whole
list goes with `SessionEnd`, a `SessionStart` that starts over, the agent
quitting and the session closing. Twelve lines are kept per session, the oldest
finished one making room first, and sixteen calls waiting for their agents.

**The list rides on the session's snapshot**, decoded leniently like
`hostsAgent`: an app meeting an older daemon shows no lines, and an older app
ignores them. The message set is unchanged, so the protocol version is too, on
purpose. A version the daemon does not speak retires it whatever it holds, and
the daemon deliberately outlives an update: bumping it would have ended every
running agent on every Mac that updated, to add a list of lines. The hook's own
event gains optional fields for the same reason — the helper is whichever build
is installed, and the daemon can be the previous one.

The cost is that the lines are Claude Code's alone, and read an undocumented
note and an undocumented list. The hooks Relay installs for Codex carry nothing
that names an agent it started.

**A turn is not finished while its agents work in the background.** The
parent's `Stop` comes as soon as it has started them — "both agents are
running, I will report when they are done" — and Claude Code hands each result
back later as a new prompt. Taking that `Stop` at its word put a check on the
session and the project with nothing to read, sent the "finished" notification
before there was a result and again when there was one, and let Clean Up
Worktrees… treat the worktree as one where nothing was going on. The rows alone
were considered as the signal and rejected for that reason: the session's
status is what the tile, the folded heading, the notifications and the cleanup
all read, and each of them was wrong. So a `Stop` while a background subagent
is still going reads as `working`, and so do the three seconds after the last
of them finishes: the result came back as a prompt within a tenth of a second
in the captured runs, and without the margin the session would flicker to
finished and back in between. The parent's `Stop` is believed for as long as
its subagents keep reporting, however long that is.
The price: a question asked and answered while agents run in the background
never shows "finished" on its own, since the turn it belongs to has not.

---

# The `relay` command talks to the app, not the daemon

An agent in a Relay terminal runs `relay worktree create fix-login --agent
claude --prompt "…"` and gets what New Worktree would have given a person: the
branch named and placed the same way, an agent started in it and handed its
prompt once it is ready. That is only true if the window's own code does it, so
the command is a thin client of the app, and the app carries each request out
with the functions the sidebar and the window call — `addWorktree`,
`openCreatedWorktree`, `performWorktreeRemoval`, the worktree notes — on the
model they draw from. What a command did is on screen when it returns, and
there is no second account of a worktree to fall out of step with the first.

The daemon was the other candidate, since it is always running. It knows
processes and nothing else: projects, presets, worktrees and notes are the
app's, and teaching the daemon them would be a second model and a protocol
change for everyone updating. The price is that the command needs the app. It
says so — "Relay is not running", exit status 1 — rather than doing half of it.

**Three sockets side by side, all keyed by flavour through the daemon's name:**

| Socket | Between |
|---|---|
| `/tmp/relay-<uid>.sock` | the app and the daemon |
| `/tmp/relay-<uid>-hooks.sock` | an agent's hook and the daemon, one line and hang up |
| `/tmp/relay-<uid>-control.sock` | the `relay` command and the app |

The daemon tells every terminal where the control socket is
(`RELAY_CONTROL_SOCKET`), because it knows which app it belongs to and the
command does not: a command typed in Relay Dev reaches Relay Dev. Outside a
Relay terminal the command takes the released app's, or Dev's with
`RELAY_FLAVOUR=dev`. The same place in the daemon adds `RELAY_CLI`, the
command's full path, and puts its directory first on `PATH` — first, though a
login shell's `path_helper` moves the system's directories back in front of it;
`RELAY_CLI` is for a profile that rebuilds `PATH` from nothing.

**One JSON line each way, then the connection closes.** A request carries a
version, the directory the command was run in, `RELAY_SESSION_ID`, and one
command encoded as an object with its name as the only key — the shape the
daemon's messages have. `ControlProtocol.version` is its own number, not
`RelayProtocolVersion`: no daemon is involved, and none is retired when it
moves. A command the app does not know is refused by name
(`unknown_command`), so an app older than the command says "update Relay"
rather than "bad request"; a new command or field needs no bump.
`ControlProtocolTests` pins the lines.

**Only this user.** The socket is `0600`, the app asks the kernel who is on the
other end (`getpeereid`), and the command will not talk to a socket in `/tmp`
that another user owns — what it sends includes the prompts it carries. A
socket file nobody answers on was left by a crash and is replaced; one that
answers belongs to another running copy of the same build, which keeps it.

**Two things about macOS sockets were learned from the tests, not the manual:**
- A connection accepted from a non-blocking listener is non-blocking too. Read
  as it came, a request a moment late was "no request" at all; the connection
  is made blocking and read with a five-second timeout instead.
- `SO_NOSIGPIPE` cannot be set on a connection whose client has already hung up,
  and answering one is then a `SIGPIPE`. The daemon ignores the signal; the app
  does not, and probing a socket for life is exactly such a client. The option
  is set on the listener, which every connection inherits it from.

**What a command is about** is decided in the app, by `ControlTargets`: the
project is the terminal's own when `RELAY_SESSION_ID` names one, or else the
one with the deepest folder or worktree holding the directory; the worktree is
the one named — a branch, a folder name, or the path of its folder — or else
the one the directory is in. A path has to be a worktree's own folder, so
`relay worktree rm src` inside a worktree does not remove it. Git's list is
read again for every command and handed to the sidebar as well, so a worktree
made in a terminal a second ago is found, and shown.

**`create` does what the window does, front and all.** When it starts an agent
in a project that is not the one in front, the project is brought forward
first: the prompt waits for the agent's terminal to exist, and the window only
ever opens on the project in front.

**The executable is `Contents/Helpers/relay`.** Not `Contents/MacOS`: its
directory goes on every terminal's `PATH`, and that one would put the app on
it as well — as `relay`, since APFS does not tell `Relay` from it. For the
same reason the SwiftPM product is `relay-cli`, and `build-app.sh` renames it.
It links nothing but `RelayProtocol`, like the hook helper: something is
waiting for it every time it runs.

**A new group of commands** is a `CommandGroup` in `Sources/relay-cli` listed
in `CommandTable`, a case and a `Name` for each command in `ControlCommand`,
and its handling in `AppModel+Control.swift`. Help, argument parsing and
`--json` come with the table.

---

# The browser pane is Chromium

A browser tab opens in a pane beside the agent building what it shows, and
design mode turns it into a pointer: click an element, and what it is — its markup, its
computed styles, the component that rendered it and the file that component is
written in, a picture of it — is typed into an agent's prompt. An Electron app
gets Chromium for free; Relay embeds it with CEF, the Chromium Embedded
Framework.

It is not free here. The framework is 320 MB unpacked and 130 MB in the
download, which takes the release archive from 14 MB to about 150 MB, and the
bundle gains five helper apps. WebKit was the alternative with no cost at all,
and was turned down because the pages being built are built for Chromium.

## The C API, against headers kept in the tree

`Sources/CChromium` holds CEF's C headers — 84 of them, the closure of the
dozen that are used — and a few hundred lines of C that implement the handlers
Relay needs and hand Swift a plain interface: an opaque page, strings, and a
table of callbacks. The C++ wrapper that CEF recommends is not used, because it
would mean building 200 C++ files with CMake before `swift build` could link.

The headers are compiled against an explicit API version, `CEF_API_VERSION`
15400, which fixes the layout of every structure in them. The framework is
loaded with `dlopen` at run time — which CEF requires on macOS anyway, for the
sandbox — and the first call asks it for the hash of the layout it speaks. A
framework that disagrees is refused before any structure is handed to it. The
consequence that matters day to day is that `swift build` and `swift test` need
nothing downloaded: only `Scripts/build-app.sh` fetches the framework, pinned by
version and checksum in `Scripts/chromium.sh`, and caches it outside the
checkout. Moving to another CEF version means replacing the headers and the pin
in the same change.

## One executable, five helpers

Chromium runs its renderers, its GPU process and its utilities as separate
processes, each started from a helper app beside the framework — `Relay
Helper.app`, and `Relay Helper (GPU).app` and three more whose names Chromium
derives from the first. They are one small executable, `relay-browser-helper`,
copied five times, each with an Info.plist that keeps it out of the Dock.

The helper starts CEF's sandbox before it loads the framework, from the
`libcef_sandbox.dylib` inside it. The helpers are signed with
`com.apple.security.cs.allow-jit`, since that is where JavaScript and the GPU
code run and the hardened runtime forbids writable executable memory without
it; the app itself is signed with no entitlement at all.

CEF also requires the application object to answer whether `-sendEvent:` is on
the stack, which a plain `NSApplication` cannot, and asks every host to
subclass it. Relay cannot: SwiftUI makes the application from a private
subclass of its own and never reads `NSPrincipalClass` — checked, not assumed,
since the subclass that was first written for this would never have been
created. So just before CEF starts, that class is given the two methods, a
`-sendEvent:` that keeps the flag, and the protocols Chromium looks for, which
the runtime matches by name.

## Started late, pumped from SwiftUI's run loop, stopped at quit

Chromium starts the first time a page is opened, not at launch: a GPU process
and a network service before a page is drawn are a cost most sessions of Relay
never need to pay. It cannot be started a second time in one process, so it
then stays.

Relay's run loop is SwiftUI's, so Chromium's work is interleaved with it rather
than given the thread: CEF names a delay, and a timer in the common modes gives
it a turn after it, which keeps pages working while a window is resized or a
menu is open. This is the scheme of CEF's own sample for such hosts; the turn
that comes anyway, for work that does not ask, comes thirty times a second
while a page is open and once a second when none is.

Quitting is the one place the terminals' rule — closing the window is not a
teardown — does not hold. The pages are in the app's process, and CEF has to be
shut down before the process ends and only once every page has closed. The app
delegate closes them, gives them two seconds of run loop to go, and shuts CEF
down if they went.

## Closing a page takes its view away

CEF's default answer to closing a page embedded in someone else's view is to
send `performClose:` to that view's window. For a pane that window is Relay's
only one, and closing it quits the app. Found in testing, where the window
being closed had no close button and nothing happened.

So the handler says it will close the page itself, and does it by taking the
page's view out of the hierarchy on the next turn of the main queue — CEF
destroys a page when its view is released. Nothing in Swift keeps a reference
to that view for the same reason. A popup, and the inspector, are in windows
CEF made for them, and those keep the default.

## The DevTools protocol is the only channel into the page

Everything Relay asks of a page — evaluating a script, waiting for a click,
taking a picture — goes through the DevTools protocol, from the browser
process, on the message channel CEF exposes. Nothing of Relay's runs in the
renderer, which is why the helper can be the few lines it is.
`DevToolsSession` numbers requests and matches replies, knowing nothing about
Chromium, and is tested without it.

Replies are handed on a turn after they arrive. Answering one usually means
sending the next question, and Chromium does not allow a message to be sent
from inside the delivery of another — it logs a failed check when that
happens, which is how this was found.

## Tabs are listed with the sessions

A project can have as many tabs as it likes, and they are opened where
sessions are — the "+" beside them, or ⇧⌘B —
and listed under them in the sidebar, because they are used the same way: to
watch the work, beside the agent doing it. They sit below the sessions in an
order of their own rather than among them; a tab is not a process, and the
daemon, which owns the session list, knows nothing about tabs. Their
identifiers are made by Relay, and the workspace file keeps them as an ordered
list with each tab's address and title.

A tab moves through the panes by the rule a session does: choosing one takes
the place of the tab on screen, and a tab never takes the place of a terminal
or a file. The first tab on screen goes to the right of the pane being worked
in. Closing a tab shows the next one that is not already on screen, the way
closing a terminal shows the next session. A link that asks for a new tab gets
one.

A tab costs nothing until it is looked at: its Chromium page is created the
first time its pane reaches the window, so a relaunch that restores a dozen
tabs starts none of them.

## Design mode trusts the page with nothing

The picker runs in the page's own JavaScript world rather than an isolated one,
because React, Vue and Svelte keep what rendered an element as properties on
the element, and those are invisible from anywhere else. The page can
therefore see the picker and replace anything it calls, so what comes back is
treated as untrusted: `DesignPick` clamps every field again on the way in, and
the script itself drops query strings, fragments, secret-looking values and
event handlers before anything leaves the page. The overlay is a closed shadow
root, out of reach of the page's styles and selectors.

Waiting for the click is one `Runtime.evaluate` of a promise that settles on
it, rather than polling. The promise is made by an `async` function, because a
page that has replaced `Promise` — Angular's zone does — would otherwise hand
back an object the protocol does not wait for. A navigation takes the overlay
with the document, and the next finished load puts it back.

Where an element is written comes from what each framework leaves in
development builds: React 18's `_debugSource`, exact; React 19's `_debugStack`,
the line as the dev server serves the file, which transpiling may have moved
and which the transcript says so about; Vue's `__file`; Svelte's
`__svelte_meta`. The picture is `Page.captureScreenshot` clipped to the part of
the element on screen, saved under `~/.relay/design` and cleared after a week,
and handed to the agent by path — a terminal carries text, and both Claude Code
and Codex open an image named by its path.

The transcript is typed into the prompt the way review notes are, as one paste
and not submitted, and the overlay comes back for the next click: the loop is
point, hand over, watch it change, point again.
