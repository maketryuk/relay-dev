# Working on Relay

Conventions for this repository. They exist so the same things do not have to be
asked for twice.

## Releases

Every change that reaches `main` and is worth a user noticing gets a release, and
a release is more than a tag:

1. **Bump the version** in `Sources/RelayProtocol/RelayVersion.swift`. It is the
   single source of truth — the build script reads it, so the bundle, the daemon
   and the About pane cannot disagree. Semantic versioning: a breaking change to
   stored data or the daemon protocol bumps the major, a feature bumps the minor,
   a fix bumps the patch.
2. **Write the changelog entry** in `CHANGELOG.md` before tagging, grouped into
   Added / Changed / Fixed. Describe what changed for the person using the app,
   not which files moved. A fix entry says what was broken.
3. **Tag** `vX.Y.Z` and push it.
4. **Publish a GitHub release** on that tag with the changelog section as its
   body. A tag with no notes tells nobody anything.

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
