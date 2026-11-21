import XCTest
@testable import PaddockCore

final class ServicePortsTests: XCTestCase {
    private func recipe(_ ports: [(String, Int)]) -> ServiceRecipe {
        ServiceRecipe(kind: "sample", displayName: "Sample", version: "1", licence: "MIT", assets: [],
                      start: RecipeCommand(executable: "/bin/true"), ready: .tcp(port: "{port.main}"),
                      ports: ports.map { RecipePort(name: $0.0, preferred: $0.1) })
    }

    func testPreferredPortWhenFree() throws {
        XCTAssertEqual(try ServicePorts.choose(for: recipe([("smtp", 1025), ("http", 8025)]), taken: [],
                                               isFree: { _ in true }),
                       ["smtp": 1025, "http": 8025])
    }

    func testPreferredTakenByAnotherInstanceGivesNextPort() throws {
        // Another instance owns 5432 even though it is stopped (so nothing listens there).
        XCTAssertEqual(try ServicePorts.choose(for: recipe([("main", 5432)]), taken: [5432, 5433],
                                               isFree: { _ in true }),
                       ["main": 5434])
    }

    func testPreferredBusyGivesNextFreePort() throws {
        let busy: Set<Int> = [8025, 8026]
        XCTAssertEqual(try ServicePorts.choose(for: recipe([("http", 8025)]), taken: [],
                                               isFree: { !busy.contains($0) }),
                       ["http": 8027])
    }

    func testPortsOfOneRecipeNeverCollide() throws {
        XCTAssertEqual(try ServicePorts.choose(for: recipe([("a", 4000), ("b", 4000)]), taken: [],
                                               isFree: { _ in true }),
                       ["a": 4000, "b": 4001])
    }

    func testGivesUpAfterTheCap() {
        XCTAssertThrowsError(try ServicePorts.choose(for: recipe([("main", 6379)]), taken: [],
                                                     isFree: { $0 > 6379 + 100 })) {
            XCTAssertEqual($0 as? ServicePortError, .noFreePort(name: "main", preferred: 6379))
        }
        // Exactly +100 is still allowed.
        XCTAssertEqual(try ServicePorts.choose(for: recipe([("main", 6379)]), taken: [],
                                               isFree: { $0 >= 6379 + 100 }), ["main": 6479])
    }

    // MARK: - Test port base

    func testPortBaseShiftsEveryPreferredPort() {
        let shifted = ServicePorts.shifted(recipe([("smtp", 1025), ("http", 8025)]), base: 30000)
        XCTAssertEqual(shifted.ports.map(\.preferred), [31025, 38025])
        XCTAssertEqual(ServicePorts.shifted(recipe([("main", 1025)]), base: nil).ports.map(\.preferred), [1025])
    }

    func testPortBaseIsReadOnlyInDevelopmentHomes() {
        XCTAssertEqual(ServicePorts.portBase(environment: ["PADDOCK_HOME": "/tmp/x",
                                                           "PADDOCK_SERVICE_PORT_BASE": "30000"]), 30000)
        XCTAssertNil(ServicePorts.portBase(environment: ["PADDOCK_SERVICE_PORT_BASE": "30000"]),
                     "a real home ignores it")
        XCTAssertNil(ServicePorts.portBase(environment: ["PADDOCK_HOME": "", "PADDOCK_SERVICE_PORT_BASE": "30000"]))
        XCTAssertNil(ServicePorts.portBase(environment: ["PADDOCK_HOME": "/tmp/x", "PADDOCK_SERVICE_PORT_BASE": "x"]))
        XCTAssertNil(ServicePorts.portBase(environment: ["PADDOCK_HOME": "/tmp/x", "PADDOCK_SERVICE_PORT_BASE": "-5"]))
        XCTAssertNil(ServicePorts.portBase(environment: ["PADDOCK_HOME": "/tmp/x", "PADDOCK_SERVICE_PORT_BASE": "60000"]),
                     "would push conventional ports past 65535")
        XCTAssertNil(ServicePorts.portBase(environment: ["PADDOCK_HOME": "/tmp/x"]))
    }
}
