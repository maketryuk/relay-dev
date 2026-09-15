import Foundation
import Testing

@testable import RelayAppKit

@Suite("Version comparison")
struct SemanticVersionTests {
    @Test("A tag and a bare version parse the same")
    func parsesBothSpellings() {
        #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("A pre-release keeps its tag")
    func parsesPreRelease() {
        #expect(SemanticVersion("0.1.0-dev")?.preRelease == "dev")
        #expect(SemanticVersion("0.1.0")?.preRelease == "")
    }

    @Test("Anything that is not a version is refused")
    func refusesNonsense() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("main") == nil)
        #expect(SemanticVersion("1.2") == nil)
        #expect(SemanticVersion("1.2.x") == nil)
    }

    @Test("Numbers compare as numbers, not as text")
    func comparesNumerically() {
        // "10" sorts before "9" as text, which is how a release gets missed.
        #expect(SemanticVersion("0.9.0")! < SemanticVersion("0.10.0")!)
        #expect(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        #expect(SemanticVersion("0.1.2")! > SemanticVersion("0.1.1")!)
    }

    @Test("A development build comes before the release it leads to")
    func preReleasePrecedesItsRelease() {
        // The first pair the updater will ever meet: 0.1.0-dev looking at 0.1.0.
        #expect(SemanticVersion("0.1.0-dev")! < SemanticVersion("0.1.0")!)
        #expect(!(SemanticVersion("0.1.0")! < SemanticVersion("0.1.0-dev")!))
    }

    @Test("Equal versions are equal, however they were written")
    func equality() {
        #expect(!(SemanticVersion("v1.0.0")! < SemanticVersion("1.0.0")!))
        #expect(!(SemanticVersion("1.0.0")! < SemanticVersion("v1.0.0")!))
    }
}

@Suite("Release feed")
struct ReleaseFeedTests {
    private func feed(_ entries: String) -> Data {
        Data("[\(entries)]".utf8)
    }

    private let published = """
    {
      "tag_name": "v0.2.0",
      "name": "0.2.0",
      "draft": false,
      "prerelease": false,
      "html_url": "https://github.com/maketryuk/relay-dev/releases/tag/v0.2.0",
      "body": "Notes",
      "assets": [{"name": "Relay.app.zip", "browser_download_url": "https://example.invalid/Relay.app.zip"}]
    }
    """

    @Test("A published release with an application is offered")
    func readsAPublishedRelease() throws {
        let release = try #require(ReleaseFeed.latest(from: feed(published)))
        #expect(release.version == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(release.downloadURL.absoluteString == "https://example.invalid/Relay.app.zip")
        #expect(release.notes == "Notes")
    }

    @Test("A draft is not a release")
    func skipsDrafts() {
        let draft = published.replacingOccurrences(of: "\"draft\": false", with: "\"draft\": true")
        #expect(ReleaseFeed.latest(from: feed(draft)) == nil)
    }

    @Test("A pre-release is read and flagged rather than discarded")
    func keepsPreReleases() throws {
        // Whether one is worth offering depends on what is running, which is a
        // different question from what was published.
        let early = published.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
        let release = try #require(ReleaseFeed.latest(from: feed(early)))
        #expect(release.isPreRelease)
    }

    @Test("A release with nothing to install is an announcement, not an update")
    func skipsReleasesWithoutAnApplication() {
        let empty = published.replacingOccurrences(
            of: "[{\"name\": \"Relay.app.zip\", \"browser_download_url\": \"https://example.invalid/Relay.app.zip\"}]",
            with: "[]"
        )
        #expect(ReleaseFeed.latest(from: feed(empty)) == nil)
    }

    @Test("The application is picked out from among the other assets")
    func choosesTheRightAsset() throws {
        // GitHub adds source archives of its own, and a release often carries a
        // checksum file; installing either would be worse than finding nothing.
        let mixed = published.replacingOccurrences(
            of: "[{\"name\": \"Relay.app.zip\", \"browser_download_url\": \"https://example.invalid/Relay.app.zip\"}]",
            with: """
            [{"name": "checksums.txt", "browser_download_url": "https://example.invalid/checksums.txt"},
             {"name": "Source code (zip)", "browser_download_url": "https://example.invalid/source.zip"},
             {"name": "Relay.app.zip", "browser_download_url": "https://example.invalid/Relay.app.zip"}]
            """
        )
        let release = try #require(ReleaseFeed.latest(from: feed(mixed)))
        #expect(release.downloadURL.lastPathComponent == "Relay.app.zip")
    }

    @Test("A tag that is not a version is ignored")
    func skipsUnparseableTags() {
        let odd = published.replacingOccurrences(of: "\"tag_name\": \"v0.2.0\"", with: "\"tag_name\": \"nightly\"")
        #expect(ReleaseFeed.latest(from: feed(odd)) == nil)
    }

    @Test("The newest release wins, whatever order they arrive in")
    func picksTheNewest() throws {
        let older = published
            .replacingOccurrences(of: "v0.2.0", with: "v0.1.0")
            .replacingOccurrences(of: "\"name\": \"0.2.0\"", with: "\"name\": \"0.1.0\"")
        let release = try #require(ReleaseFeed.latest(from: feed("\(published),\(older)")))
        #expect(release.version == SemanticVersion(major: 0, minor: 2, patch: 0))
    }

    @Test("Anything that is not the expected shape is refused rather than guessed at")
    func refusesGarbage() {
        #expect(ReleaseFeed.latest(from: Data("not json".utf8)) == nil)
        #expect(ReleaseFeed.latest(from: Data("{}".utf8)) == nil)
        #expect(ReleaseFeed.latest(from: Data("[]".utf8)) == nil)
    }
}

@Suite("Update decision")
struct UpdateDecisionTests {
    private func release(_ version: String, isPreRelease: Bool = false) -> Release {
        Release(
            version: SemanticVersion(version)!,
            name: version,
            downloadURL: URL(string: "https://example.invalid/Relay.app.zip")!,
            pageURL: URL(string: "https://example.invalid")!,
            notes: "",
            isPreRelease: isPreRelease
        )
    }

    @Test("A newer release is offered")
    func offersNewer() {
        #expect(UpdateDecision.isWorthOffering(release("0.2.0"), running: SemanticVersion("0.1.0")!))
    }

    @Test("The version already running is not an update")
    func ignoresTheSameVersion() {
        #expect(!UpdateDecision.isWorthOffering(release("0.2.0"), running: SemanticVersion("0.2.0")!))
    }

    @Test("A build ahead of the newest tag is not offered a downgrade")
    func ignoresOlderReleases() {
        // A build made from main is legitimately ahead of the last release, and
        // calling that an update would walk the user backwards.
        #expect(!UpdateDecision.isWorthOffering(release("0.1.0"), running: SemanticVersion("0.2.0-dev")!))
    }

    @Test("A development build is offered the release it leads to")
    func offersTheReleaseADevBuildLeadsTo() {
        #expect(UpdateDecision.isWorthOffering(release("0.1.0"), running: SemanticVersion("0.1.0-dev")!))
    }

    @Test("The first check happens immediately, later ones wait")
    func checkPacing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateDecision.shouldCheckNow(lastCheckedAt: nil, now: now))
        #expect(!UpdateDecision.shouldCheckNow(lastCheckedAt: now.addingTimeInterval(-60), now: now))
        #expect(UpdateDecision.shouldCheckNow(
            lastCheckedAt: now.addingTimeInterval(-UpdateDecision.checkInterval - 1),
            now: now
        ))
    }

    @Test("A development build is offered a pre-release")
    func preReleasesReachDevelopmentBuilds() {
        // Which is the only way to exercise the update path before there is a
        // release anyone would want to cut.
        #expect(UpdateDecision.isWorthOffering(
            release("0.1.0-rc1", isPreRelease: true),
            running: SemanticVersion("0.1.0-dev")!
        ))
    }

    @Test("A released build is left on released builds")
    func preReleasesDoNotReachReleases() {
        // Running 0.1.0 is not consent to be moved onto whatever is being tried
        // out next.
        #expect(!UpdateDecision.isWorthOffering(
            release("0.2.0-rc1", isPreRelease: true),
            running: SemanticVersion("0.1.0")!
        ))
    }
}
