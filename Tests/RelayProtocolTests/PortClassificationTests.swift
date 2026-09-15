import Foundation
import Testing

@testable import RelayProtocol

@Suite("Development port classification")
struct PortClassificationTests {
    private func port(
        _ number: Int,
        process: String,
        managed: Bool = false
    ) -> ListeningPort {
        ListeningPort(
            port: number,
            address: "*",
            pid: 100,
            processName: process,
            ownerSessionID: managed ? .generate() : nil,
            ownerName: managed ? "Dev" : nil,
            ownerProjectID: managed ? .generate() : nil
        )
    }

    @Test("Anything Relay started counts, whatever it is")
    func relayOwnedAlwaysCounts() {
        // It is the user's own work by definition.
        #expect(PortClassification.isDevelopment(port(52_341, process: "unknown", managed: true)))
    }

    @Test(
        "Development runtimes count on any port",
        arguments: ["node", "python3", "ruby", "php", "postgres", "redis-server", "com.docker.backend"]
    )
    func runtimesCount(process: String) {
        #expect(PortClassification.isDevelopment(port(61_234, process: process)))
    }

    @Test(
        "macOS services are filtered out even on development-looking ports",
        arguments: [
            (5_000, "ControlCenter"),
            (7_000, "ControlCenter"),
            (58_185, "rapportd"),
            (3_031, "sharingd"),
        ]
    )
    func systemServicesAreHidden(number: Int, process: String) {
        // Control Centre answers on 5000 and 7000, which look exactly like a dev
        // server and are the reason an unfiltered list is unusable.
        #expect(!PortClassification.isDevelopment(port(number, process: process)))
    }

    @Test(
        "Conventional development ports count even from an unknown process",
        arguments: [3_000, 3_001, 4_200, 5_173, 8_080, 9_229, 24_678]
    )
    func developmentRangesCount(number: Int) {
        #expect(PortClassification.isDevelopment(port(number, process: "mystery")))
    }

    @Test(
        "Well-known infrastructure ports count",
        arguments: [5_432, 3_306, 6_379, 27_017, 9_200, 1_025, 8_025]
    )
    func infrastructurePortsCount(number: Int) {
        #expect(PortClassification.isDevelopment(port(number, process: "mystery")))
    }

    @Test(
        "Unrelated high ports from unknown processes are filtered out",
        arguments: [49_152, 52_900, 55_347, 63_342]
    )
    func randomHighPortsAreHidden(number: Int) {
        #expect(!PortClassification.isDevelopment(port(number, process: "agent-server")))
    }

    @Test("A system process name outranks a development port number")
    func systemNameWinsOverPortNumber() {
        // Otherwise Control Centre reappears the moment it picks port 8000.
        #expect(!PortClassification.isDevelopment(port(8_000, process: "ControlCenter")))
    }

    @Test("Classification never crashes on odd input")
    func toleratesOddInput() {
        #expect(!PortClassification.isDevelopment(port(1, process: "")))
        #expect(PortClassification.isDevelopment(port(3_000, process: "")))
    }
}
