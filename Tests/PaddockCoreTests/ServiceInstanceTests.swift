import XCTest
@testable import PaddockCore

final class ServiceInstanceTests: XCTestCase {
    private func makePaths() throws -> Paths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Paths(home: dir)
    }

    private let mail = ServiceInstance(id: "mail", kind: "mail", version: "1.34.0", name: "Mail",
                                       ports: ["smtp": 1025, "http": 8025], autostart: true,
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: - State

    func testStateRoundTripWithServices() throws {
        let paths = try makePaths()
        let mail = self.mail
        let written = try StateStore(paths: paths).update {
            $0.services = [mail]
            $0.links["blog"] = "/tmp/blog"
        }
        let loaded = StateStore(paths: paths).load()
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded.services, [mail])
    }

    /// A state.json written before services existed reads with none, and keeps everything else.
    func testStateWithoutServicesDecodes() throws {
        let paths = try makePaths()
        let old = """
        {"parked": ["/tmp/sites"], "links": {"blog": "/tmp/blog"}, "secured": ["blog"],
         "phpPins": {}, "defaultPHP": "8.5"}
        """
        try Data(old.utf8).write(to: paths.stateFile)
        let state = StateStore(paths: paths).load()
        XCTAssertEqual(state.services, [])
        XCTAssertEqual(state.parked, ["/tmp/sites"])
        XCTAssertEqual(state.links, ["blog": "/tmp/blog"])
        XCTAssertEqual(state.secured, ["blog"])
        XCTAssertEqual(state.defaultPHP, PHPVersion("8.5"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
            .contains { $0.hasPrefix("state.json.corrupt-") })
    }

    // MARK: - Ids and names

    func testIDsAndNames() {
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "mail", version: "1.34.0", displayName: "Mail",
                                                   kindHasSeveralVersions: false, existing: []),
                       .init(id: "mail", name: "Mail"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "mail", version: "1.34.0", displayName: "Mail",
                                                   kindHasSeveralVersions: false, existing: ["mail"]),
                       .init(id: "mail-2", name: "Mail (2)"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "postgres", version: "18.1", displayName: "PostgreSQL",
                                                   kindHasSeveralVersions: true, existing: ["mail"]),
                       .init(id: "postgres-18", name: "PostgreSQL 18"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "postgres", version: "18.1", displayName: "PostgreSQL",
                                                   kindHasSeveralVersions: true,
                                                   existing: ["postgres-18", "postgres-18-2"]),
                       .init(id: "postgres-18-3", name: "PostgreSQL 18 (3)"))
        XCTAssertTrue(ServiceInstance.isValidID("postgres-18-2"))
        for bad in ["", "Mail", "a b", "../x", "a/b", "a.b", "é", "-", "x-"] {
            XCTAssertFalse(ServiceInstance.isValidID(bad), bad)
        }
    }

    func testMatchingNamesIsCaseInsensitiveByIDOrName() {
        let pg = ServiceInstance(id: "postgres-18", kind: "postgres", version: "18.1", name: "PostgreSQL 18",
                                 ports: ["main": 5432], autostart: true, createdAt: Date())
        let list = [mail, pg]
        XCTAssertEqual(ServiceInstance.find("MAIL", in: list)?.id, "mail")
        XCTAssertEqual(ServiceInstance.find("postgresql 18", in: list)?.id, "postgres-18")
        XCTAssertEqual(ServiceInstance.find("Postgres-18", in: list)?.id, "postgres-18")
        XCTAssertNil(ServiceInstance.find("postgres", in: list))
    }

    // MARK: - Paths

    func testServicePaths() {
        let paths = Paths(home: URL(fileURLWithPath: "/h", isDirectory: true))
        XCTAssertEqual(paths.services.path, "/h/services")
        XCTAssertEqual(paths.serviceBin(kind: "mail", version: "1.34.0").path, "/h/services/bin/mail/1.34.0")
        XCTAssertEqual(paths.serviceHome("mail").path, "/h/services/mail")
        XCTAssertEqual(paths.serviceData("mail").path, "/h/services/mail/data")
        XCTAssertEqual(paths.serviceConfig("mail").path, "/h/services/mail/config")
        XCTAssertEqual(paths.serviceRun("mail").path, "/h/run/svc/mail")
        XCTAssertEqual(paths.serviceLog("mail").path, "/h/log/service-mail.log")
    }

    // MARK: - Status on the wire

    func testServiceStatusRoundTripsAndOldStatusHasNoServices() throws {
        let status = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1.34.0", displayName: "Mail",
                                   state: .portInUse(holder: "nc (pid 5)"), ports: ["smtp": 1025, "http": 8025],
                                   env: ["MAIL_PORT=1025"], openURL: "http://127.0.0.1:8025",
                                   dataPath: "/h/services/mail/data", autostart: true, mainPort: 1025)
        for state in [ServiceState.running, .starting, .stopped, .crashed, .portInUse(holder: "x"),
                      .unavailable(reason: "y")] {
            var copy = status
            copy.state = state
            XCTAssertEqual(try JSONDecoder().decode(ServiceStatus.self, from: JSONEncoder().encode(copy)), copy)
        }
        var engine = EngineStatus(running: true, blockedBy: [], sites: [], installedPHP: [], defaultPHP: nil,
                                  processes: [:], resolverInstalled: false, trustEnabled: false, dnsRunning: true,
                                  portHelperInstalled: true)
        engine.services = [status]
        XCTAssertEqual(try JSONDecoder().decode(EngineStatus.self, from: JSONEncoder().encode(engine)), engine)

        let old = try JSONDecoder().decode(EngineStatus.self, from: Data(#"{"running": true, "version": 3}"#.utf8))
        XCTAssertEqual(old.services, [])
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 4, "the status changed: the build number moves on")
    }
}
