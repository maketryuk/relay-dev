import Foundation
import Testing

@testable import RelayAppKit

@Suite("Project discovery")
struct ProjectDiscoveryTests {
    @Test("A bare directory yields its own name and nothing else")
    func bareDirectory() throws {
        let directory = try TemporaryDirectory()
        let facts = ProjectDiscovery.inspect(path: directory.url.path)
        #expect(facts.suggestedName == directory.url.lastPathComponent)
        #expect(!facts.isGitRepository)
        #expect(facts.packageManager == nil)
        #expect(facts.devCommand == nil)
        #expect(!facts.hasDocker)
    }

    @Test("package.json supplies the project name")
    func nameFromPackageJSON() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"name": "@acme/storefront"}"#, to: "package.json")
        let facts = ProjectDiscovery.inspect(path: directory.url.path)
        #expect(facts.suggestedName == "@acme/storefront")
    }

    @Test(
        "The package manager is inferred from the lockfile, not from package.json",
        arguments: [
            ("pnpm-lock.yaml", "pnpm"),
            ("bun.lockb", "bun"),
            ("yarn.lock", "yarn"),
            ("package-lock.json", "npm"),
        ]
    )
    func packageManagerFromLockfile(lockfile: String, expected: String) throws {
        let directory = try TemporaryDirectory()
        try directory.write("{}", to: "package.json")
        try directory.write("", to: lockfile)
        let facts = ProjectDiscovery.inspect(path: directory.url.path)
        #expect(facts.packageManager == expected)
    }

    @Test("A package.json with no lockfile falls back to npm")
    func packageManagerFallback() throws {
        let directory = try TemporaryDirectory()
        try directory.write("{}", to: "package.json")
        #expect(ProjectDiscovery.inspect(path: directory.url.path).packageManager == "npm")
    }

    @Test("The dev command combines the package manager with the script")
    func devCommandFromScripts() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"scripts": {"dev": "vite"}}"#, to: "package.json")
        try directory.write("", to: "pnpm-lock.yaml")
        #expect(ProjectDiscovery.inspect(path: directory.url.path).devCommand == "pnpm run dev")
    }

    @Test("`dev` is preferred over `start` when both exist")
    func devScriptPreferenceOrder() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"scripts": {"start": "node .", "dev": "vite", "serve": "http"}}"#, to: "package.json")
        #expect(ProjectDiscovery.inspect(path: directory.url.path).devCommand == "npm run dev")
    }

    @Test("A project with only `start` uses it")
    func startScriptFallback() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"scripts": {"start": "node ."}}"#, to: "package.json")
        #expect(ProjectDiscovery.inspect(path: directory.url.path).devCommand == "npm run start")
    }

    @Test("A project with no recognised script has no dev command")
    func noDevScript() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"scripts": {"build": "tsc", "lint": "eslint ."}}"#, to: "package.json")
        #expect(ProjectDiscovery.inspect(path: directory.url.path).devCommand == nil)
    }

    @Test(
        "Every compose filename the spec lists is recognised",
        arguments: ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    )
    func composeDiscovery(filename: String) throws {
        let directory = try TemporaryDirectory()
        try directory.write("services: {}", to: filename)
        let facts = ProjectDiscovery.inspect(path: directory.url.path)
        #expect(facts.composeFile == filename)
        #expect(facts.hasDocker)
    }

    @Test("A Dockerfile alone is enough to show the Docker section")
    func dockerfileOnly() throws {
        let directory = try TemporaryDirectory()
        try directory.write("FROM alpine", to: "Dockerfile")
        let facts = ProjectDiscovery.inspect(path: directory.url.path)
        #expect(facts.hasDockerfile)
        #expect(facts.composeFile == nil)
        #expect(facts.hasDocker)
    }

    @Test("Malformed package.json does not break discovery")
    func malformedPackageJSON() throws {
        let directory = try TemporaryDirectory()
        try directory.write("{ this is not json", to: "package.json")
        let facts = ProjectDiscovery.inspect(path: directory.url.path)
        #expect(facts.suggestedName == directory.url.lastPathComponent)
        #expect(facts.devCommand == nil)
    }

    @Test("An empty name in package.json is ignored")
    func emptyNameIgnored() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"name": ""}"#, to: "package.json")
        #expect(ProjectDiscovery.inspect(path: directory.url.path).suggestedName == directory.url.lastPathComponent)
    }
}
