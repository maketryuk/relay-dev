# Working on Relay

Conventions for this repository. They exist so the same things do not have to be
asked for twice.

## Releases

**Never tag or publish a release without being asked to.** Work lands on `main`
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
4. **Build the archive locally** with `./Scripts/build-app.sh`, which leaves
   `build/Relay.app.zip` beside the bundle. It has to be built on a machine
   holding the signing certificate: a CI runner produces an ad-hoc signature,
   and replacing a properly signed copy with one breaks the app's identity with
   macOS — every permission is asked for again.
5. **Publish a GitHub release** on that tag with the changelog section as its
   body, and attach `Relay.app.zip`. A tag with no notes tells nobody anything,
   and a release with no archive is invisible to the in-app updater: it looks
   for an asset whose name starts with `Relay` and ends in `.zip`, and a release
   without one is treated as an announcement rather than an update.

## Daemon protocol

`RelayProtocolVersion.current` must be bumped whenever the message set changes.
The daemon deliberately outlives the GUI, so a new build routinely meets the
previous build's daemon; the version is what lets the client notice and retire
it. Adding cases stays backwards compatible, reordering or removing them does
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
