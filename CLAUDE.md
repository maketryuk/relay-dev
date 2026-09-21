# Working on Relay

Conventions for this repository. They exist so the same things do not have to be
asked for twice.

## Commits

- **The subject is a sentence about what changed for the person using Relay**,
  in the imperative and without a prefix: `Let the project header be typed into
  while a session runs`. No type, no scope, no ticket — this history is read by
  people rather than parsed by a generator, and `fix(ui):` says nothing the
  sentence does not. The one exception is a release, which is `Relay X.Y.Z`.
- **The body is prose, and it is about why.** What was wrong, what the mechanism
  turned out to be, what the fix costs and what it gives up. The changelog entry
  is one line for the user; the commit is the whole account, and it is where the
  reasoning that would go stale in a comment belongs.
- **English only**, subject and body, whatever language the work was discussed
  in.
- **One concern per commit.** A fix noticed along the way gets its own commit
  rather than being folded into the feature — a mixed commit cannot be reverted,
  and splitting costs nothing.
- **Committing is asked for, never assumed**, the same as tagging and pushing.

## Before finishing

- **`swift build` and `swift test` both green, and shown.** A change that
  compiles in an editor and has never been run is unverified; saying it works is
  then a guess. A warning counts as a failure — a release build has none, so a
  warning introduced here is a release that cannot be cut.
- **A phrase the interface shows goes into both string tables in the same
  change.** `Tests/RelayAppKitTests/LocalizationTests.swift` reads every
  `relayLocalized` call in the tree and fails on one with no entry, because a
  missing translation is invisible: it shows English in a Russian window and
  nothing anywhere says so.
- **A doc is part of the change, not a follow-up** — `docs/` and this file are
  corrected in the same commit as the code they describe.
- **No plan, contract or checklist documents.** Nothing named `plan.md`,
  `TASKS.md` or `api-contract.md`, and no third place to look: what the code
  does belongs beside it in a comment and in a test that fails when the answer
  changes, and what is left to do belongs in `docs/ROADMAP.md`.
- **Nothing is built, installed or launched to look at unless it was asked
  for.** `make dev-install` and starting a daemon by hand have consequences
  outside the checkout — another copy of the app, another process holding a
  socket — and the evidence for a change is the build and the tests.

## Releases

**Never tag or publish a release without being asked to.** Work lands on `master`
and accumulates under `## Unreleased` in `CHANGELOG.md`.

### What the numbers mean

`MAJOR.MINOR.BUILD`, and the last one is a **build counter, not a bug count**.
It goes up by one for every build that is published and resets to zero when the
minor moves. `0.2.47` is the forty-seventh build of the 0.2 line, and says
nothing about how many things were fixed in it.

- **Build** — every published build. No judgement required: if it ships, the
  number goes up. Gaps are fine and expected, since a build that is never
  published still consumed its number.
- **Minor** — a milestone worth telling someone about. Rare and deliberate.
- **Major** — breaking changes to stored data.

This is how a continuously updated app is normally numbered: the user never
reads the number, the updater only needs to order two of them, and nobody has
to decide whether a day's work "deserves" a version. Before it, the question
"is this enough for a release?" had to be answered every time, which is a
question about nothing.

### Cutting one

1. **Bump the version** with `./Scripts/bump-version.sh`: `build` by default,
   `minor` for a milestone, `release` to turn a candidate into the version it
   was a candidate for. A `build` bump while a candidate is current moves the
   candidate on instead, so a version that has not shipped is never stepped
   over. It edits
   `Sources/RelayProtocol/RelayVersion.swift`, which is the single source of
   truth: the build script reads it, so the bundle, the daemon and the About
   pane cannot disagree.
2. **Rename the `Unreleased` heading** to the version, keeping the Added /
   Changed / Fixed grouping. Describe what changed for the person using the app,
   not which files moved. A fix entry says what was broken.
3. **Tag** `vX.Y.Z` and push it.
4. **Build the artefacts** with `./Scripts/release.sh`. It signs with Developer
   ID, notarises with Apple, staples the ticket into the bundle, and leaves both
   files in `build/release`: `Relay-X.Y.Z.app.zip`, which the in-app updater
   downloads, and `Relay-X.Y.Z.dmg`, which a person downloads. It refuses a
   dirty working tree, a missing changelog section and a missing certificate,
   because each of those produces a release that is wrong in a way nobody
   notices until it is installed.
5. **Publish** with `./Scripts/release.sh --publish`, which creates the release
   on the tag with the changelog section as its body and both files attached. A
   tag with no notes tells nobody anything, and a release with no `.zip` is
   invisible to the in-app updater: it looks for an asset whose name starts with
   `Relay` and ends in `.zip`, and a release without one is treated as an
   announcement rather than an update.

### What a release has to be signed with

Two things, set up once, without which step 4 stops before it builds anything:

- A **Developer ID Application** certificate. Xcode → Settings → Accounts →
  the team → Manage Certificates → + → Developer ID Application; for an
  organisation only the account holder can create one. An *Apple Development*
  certificate is not a substitute: it signs builds for the machine that made
  them, every other Mac refuses them, and Apple will not notarise them.
- **Notarisation credentials** stored in the keychain as `relay-notary` (or
  whatever `RELAY_NOTARY_PROFILE` says), either from an Apple ID and an
  app-specific password:
  `xcrun notarytool store-credentials "relay-notary" --apple-id <id>
  --team-id L79UA6HS32 --password <app-specific-password>`,
  or from an App Store Connect API key:
  `xcrun notarytool store-credentials "relay-notary" --key AuthKey_XXX.p8
  --key-id XXXXXXXXXX --issuer <issuer-uuid>`.

Both live on the machine that cuts releases, which is why this is not in CI: a
runner has neither, and would quietly produce an ad-hoc signature that breaks
the app's identity with macOS — every permission asked for again, and the
in-app updater refusing the download as signed by someone else.

Development builds are signed with the same Developer ID when it is present, so
that switching between a local build and a released one does not look like a
different app to macOS. They carry the hardened runtime too, so what is tested
is what ships; only the timestamp Apple has to witness is left out, because it
costs a round trip on every build.

### Cutting one before that is settled

`RELAY_UNSIGNED=1 ./Scripts/release.sh` builds a release with neither. It signs
with whatever certificate is to hand — an *Apple Development* one will do —
because the in-app updater refuses a download whose team is not the team already
running, and an ad-hoc signature has no team at all. It skips notarisation, and
it skips the disk image, which unsigned is the worst of both: a download that
looks official and opens nowhere.

What that costs: a Mac other than the one that built it refuses the download
until it is talked round in System Settings. What it does not cost: the in-app
updater, which asks whether the team matches rather than whether Apple has
blessed it, so an existing install updates itself as usual.

The team is what has to hold, not the certificate. Moving later to a Developer
ID issued under the same team keeps every existing install updating; moving to
one under a different team does not, and everybody has to install by hand once.

## Working in Relay while working on Relay

`make dev-install` builds **Relay Dev**, which stands beside the released app
instead of replacing it. Work in Relay; build in Relay Dev.

They are two identities, not two copies. Everything that would let them reach
each other is keyed by `RelayFlavour`: the bundle identifier, the name, the
home directory it keeps its files in — `~/.relay` against `~/.relay-dev` — the
socket, the log, and whether the updater is allowed to run at all.
`RELAY_FLAVOUR=dev` is read by the build script, the install script and the code
alike, so the bundle and what runs inside it cannot disagree.

Two copies of one identity does not work, and the reason is worth knowing. The
client replaces a daemon whose binary is not the one it shipped with — right for
a single app, since a new build must not talk to old code. But the daemon hash
changes on **every** build, signature and all, so a development app sharing the
socket would take over the daemon the released one is using. They would also
share one `workspace.json`, where the last writer wins.

What happens to the sessions in a daemon that is not ours is decided by
`DaemonSuccession`: an idle one is shut down and replaced at once, and one with
sessions in it is **inherited** — kept, scrollback and all, until the last
session closes, at which point the changeover finishes on its own. Replacing it
tears down every PTY it holds, which is a price worth paying for a daemon
supervising nothing and never worth paying for one supervising an afternoon's
work; an update used to pay it every time. The cost is that a change to daemon
code does not take effect while a session from the previous build is open — so
when working on the daemon, close the sessions, or end it outright with
`pkill relay-daemon`.

The daemon cannot read its own flavour: it is a bare executable inside
`Contents/MacOS` with no bundle identifier, so `DaemonLauncher` puts it in the
environment. A daemon started by hand is the released one, which is the safe
default for `make daemon`.

## Daemon protocol

`RelayProtocolVersion.current` must be bumped whenever the message set changes.
The daemon deliberately outlives the GUI, so a new build routinely meets the
previous build's daemon; the version is what lets the client notice. A daemon
that cannot decode what this build sends is retired whatever it is holding,
since it is no use to those sessions either — which is why adding a case is
not the same kind of change as reordering one. Adding cases stays backwards compatible, reordering or removing them does
not — `Tests/RelayProtocolTests/WireCompatibilityTests.swift` pins the encodings
the upgrade path depends on.

## Tests

- Real behaviour is tested against the real thing: the daemon suite starts an
  actual daemon on a throwaway socket and drives actual processes in actual
  PTYs.
- Parsers are pure functions tested against captured fixtures. Mocks appear only
  where the alternative is depending on the developer's own `~/.ssh` or a
  running Docker engine.
- **Never assert on the state of the machine the tests run on.** A clean CI
  runner has no stray listening ports, no containers and no git identity.
- **Nor on how busy it is.** A test that times something times the window it
  cares about and no more, and waits for a thing to have happened rather than
  for a delay to have passed: a suite of tests that sit inside processes of
  their own leaves a shared queue minutes behind itself, and a timer scheduled
  on one arrives whenever it arrives. CI runs the suite `--no-parallel` for the
  same reason — three cores, and a test waiting on a process holds a thread
  while it waits.
- A test written for a bug must be shown to fail without the fix.

## Compatibility

CI runs an older Swift than a current Mac usually has. Code that compiles
locally is not proven; `swift build` passing in CI is. Prefer explicit
annotations over whatever the newest compiler happens to infer.

## Style

- Comments explain why, never what. If a line needs a comment to say what it
  does, rewrite the line.
- Follow the surrounding code's naming and idiom.
- No warnings in a release build.
