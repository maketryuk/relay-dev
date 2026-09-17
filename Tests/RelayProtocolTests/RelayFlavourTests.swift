import Foundation
import Testing

@testable import RelayProtocol

@Suite("Build flavour")
struct RelayFlavourTests {
    @Test("The app knows which build it is from its own identifier")
    func readsTheBundleIdentifier() {
        #expect(
            RelayFlavour.resolve(environment: nil, bundleIdentifier: "studio.lince.relay.dev") == .development
        )
        #expect(RelayFlavour.resolve(environment: nil, bundleIdentifier: "studio.lince.relay") == .release)
    }

    @Test("The daemon is told, because it has no identifier to read")
    func environmentWins() {
        // A bare executable inside Contents/MacOS has no bundle identifier of
        // its own, so the app that launches it says which build it belongs to.
        #expect(
            RelayFlavour.resolve(environment: "development", bundleIdentifier: nil) == .development
        )
        #expect(
            RelayFlavour.resolve(environment: "release", bundleIdentifier: "studio.lince.relay.dev") == .release
        )
    }

    @Test("Anything unclaimed is the ordinary app")
    func defaultsToRelease() {
        // A daemon started by hand, or a binary run out of the build directory,
        // belongs to the released app until something says otherwise.
        #expect(RelayFlavour.resolve(environment: nil, bundleIdentifier: nil) == .release)
        #expect(RelayFlavour.resolve(environment: "", bundleIdentifier: nil) == .release)
        #expect(RelayFlavour.resolve(environment: "nonsense", bundleIdentifier: nil) == .release)
    }

    @Test("What anyone would type on a command line is accepted")
    func spellingIsNotThePoint() {
        #expect(RelayFlavour.named("dev") == .development)
        #expect(RelayFlavour.named("DEV") == .development)
        #expect(RelayFlavour.named(" development ") == .development)
        #expect(RelayFlavour.named("prod") == .release)
        #expect(RelayFlavour.named("") == nil)
    }

    @Test("Nothing that keeps the two apart is shared between them")
    func theIdentitiesDiffer() {
        let release = RelayFlavour.release
        let development = RelayFlavour.development
        #expect(release.bundleIdentifier != development.bundleIdentifier)
        #expect(release.displayName != development.displayName)
        // The socket lives in a directory both builds share, so its name is the
        // only thing keeping one daemon out of the other's connections.
        #expect(release.socketName != development.socketName)
    }

    @Test("Only the released build replaces itself")
    func onlyReleaseUpdates() {
        #expect(RelayFlavour.release.allowsUpdates)
        #expect(!RelayFlavour.development.allowsUpdates)
    }
}
