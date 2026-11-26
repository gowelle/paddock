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

    private let mail = ServiceInstance(id: "mail", kind: "mail", series: "1", version: "1.34.0", name: "Mail",
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

    func testIDsAndNamesFollowTheSeries() {
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "mail", series: "1", displayName: "Mail",
                                                   seriesInID: false, existing: []),
                       .init(id: "mail", name: "Mail"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "mail", series: "1", displayName: "Mail",
                                                   seriesInID: false, existing: ["mail"]),
                       .init(id: "mail-2", name: "Mail (2)"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "postgres", series: "18", displayName: "PostgreSQL",
                                                   seriesInID: true, existing: ["mail"]),
                       .init(id: "postgres-18", name: "PostgreSQL 18"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "mysql", series: "8.4", displayName: "MySQL",
                                                   seriesInID: true, existing: []),
                       .init(id: "mysql-8-4", name: "MySQL 8.4"))
        XCTAssertEqual(ServiceInstance.newIdentity(kind: "postgres", series: "18", displayName: "PostgreSQL",
                                                   seriesInID: true, existing: ["postgres-18", "postgres-18-2"]),
                       .init(id: "postgres-18-3", name: "PostgreSQL 18 (3)"))
        XCTAssertTrue(ServiceInstance.isValidID("postgres-18-2"))
        for bad in ["", "Mail", "a b", "../x", "..", ".", "a/b", "a.b", "é", "-", "x-", "bin"] {
            XCTAssertFalse(ServiceInstance.isValidID(bad), bad)
        }
    }

    func testMatchingNamesIsCaseInsensitiveByIDOrName() {
        let pg = ServiceInstance(id: "postgres-18", kind: "postgres", series: "18", version: "18.1", name: "PostgreSQL 18",
                                 ports: ["main": 5432], autostart: true, createdAt: Date())
        let list = [mail, pg]
        XCTAssertEqual(ServiceInstance.find("MAIL", in: list)?.id, "mail")
        XCTAssertEqual(ServiceInstance.find("postgresql 18", in: list)?.id, "postgres-18")
        XCTAssertEqual(ServiceInstance.find("Postgres-18", in: list)?.id, "postgres-18")
        XCTAssertNil(ServiceInstance.find("postgres", in: list))
    }

    /// An instance saved before series existed decodes with an empty series, which the manager fills in.
    func testAnInstanceSavedWithoutASeriesDecodes() throws {
        let json = #"{"id": "mail", "kind": "mail", "version": "1.34.0", "name": "Mail", "ports": {"smtp": 1025},"#
            + #" "autostart": true, "createdAt": 0}"#
        let instance = try JSONDecoder().decode(ServiceInstance.self, from: Data(json.utf8))
        XCTAssertEqual(instance.series, "")
        XCTAssertEqual(instance.version, "1.34.0")
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
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 6, "the status changed: the build number moves on")
    }

    /// A crash Paddock stopped restarting travels as `gaveUp`; a status from an older daemon has no such word.
    func testAGaveUpCrashTravelsInTheStatusAndIsNilFromOlderDaemons() throws {
        let crashed = ServiceStatus(id: "postgres-18", name: "PostgreSQL 18", kind: "postgres", version: "18.3.0",
                                    displayName: "PostgreSQL", state: .crashed, ports: ["main": 5432], env: [],
                                    openURL: nil, dataPath: "/h/services/postgres-18/data", autostart: true,
                                    mainPort: 5432, gaveUp: true)
        let json = String(decoding: try JSONEncoder().encode(crashed), as: UTF8.self)
        XCTAssertTrue(json.contains(#""gaveUp":true"#), json)
        XCTAssertEqual(try JSONDecoder().decode(ServiceStatus.self, from: Data(json.utf8)), crashed)

        let older = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1", displayName: "Mail",
                                  state: .running, ports: [:], env: [], openURL: nil, dataPath: "/d", autostart: true,
                                  mainPort: nil)
        XCTAssertNil(older.gaveUp)
        XCTAssertNil(try JSONDecoder().decode(ServiceStatus.self, from: JSONEncoder().encode(older)).gaveUp)
    }

    /// A newer daemon's unknown state reads as unavailable, and one service that can't be read never
    /// costs the whole status.
    func testStatusDecodingIsForwardTolerant() throws {        let state = try JSONDecoder().decode(ServiceState.self, from: Data(#"{"upgrading": {"to": "2"}}"#.utf8))
        XCTAssertEqual(state, .unavailable(reason: "unknown state"))
        let good = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1.34.0", displayName: "Mail",
                                 state: .running, ports: ["smtp": 1025], env: [], openURL: nil, dataPath: "/d",
                                 autostart: true, mainPort: 1025, updateAvailable: "1.35.0")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let text = #"{"running": true, "version": 5, "services": [{"id": 7}, "#
            + goodJSON + #", {"id": "x", "state": {"strange": {}}, "name": "X", "kind": "x", "version": "1","#
            + #" "displayName": "X", "ports": {}, "env": [], "dataPath": "/x", "autostart": false}]}"#
        let status = try JSONDecoder().decode(EngineStatus.self, from: Data(text.utf8))
        XCTAssertEqual(status.services.map(\.id), ["mail", "x"])
        XCTAssertEqual(status.services[0].updateAvailable, "1.35.0")
        XCTAssertEqual(status.services[1].state, .unavailable(reason: "unknown state"))
    }
}
