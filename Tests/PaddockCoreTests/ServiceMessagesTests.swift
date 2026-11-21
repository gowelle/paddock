import XCTest
@testable import PaddockCore

final class ServiceMessagesTests: XCTestCase {
    private func status(_ state: ServiceState, ports: [String: Int] = ["smtp": 1025, "http": 8025],
                        main: Int? = 1025) -> ServiceStatus {
        ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1.34.0", displayName: "Mail", state: state,
                      ports: ports, env: [], openURL: nil, dataPath: "/d", autostart: true, mainPort: main)
    }

    func testServiceTable() {
        XCTAssertEqual(Messages.serviceTable([status(.running), status(.portInUse(holder: "nc (pid 5)"))]), """
            SERVICE  STATE                      PORTS
            Mail     running                    1025 (smtp), 8025 (http)
            Mail     port in use by nc (pid 5)  1025 (smtp), 8025 (http)
            """)
        XCTAssertEqual(Messages.servicePorts(status(.stopped, ports: ["a": 9000, "main": 9500, "b": 8000], main: 9500)),
                       "9500 (main), 8000 (b), 9000 (a)", "the main port first, then by number")
    }

    /// A service's notes follow the table, one line each, named.
    func testServiceTableWithNotes() {
        let plain = status(.running)
        let noted = ServiceStatus(id: "postgres-18", name: "PostgreSQL 18", kind: "postgres", version: "18.7.0",
                                  displayName: "PostgreSQL", state: .running, ports: ["main": 5432], env: [], openURL: nil,
                                  dataPath: "/d", autostart: true, mainPort: 5432,
                                  notes: ["Includes PostGIS 3.6.4 (no raster or topology)."])
        XCTAssertEqual(Messages.serviceTable([plain, noted]),
                       Messages.serviceTable([plain, ServiceStatus(id: "postgres-18", name: "PostgreSQL 18", kind: "postgres",
                                                                   version: "18.7.0", displayName: "PostgreSQL", state: .running,
                                                                   ports: ["main": 5432], env: [], openURL: nil, dataPath: "/d",
                                                                   autostart: true, mainPort: 5432)])
                       + "\n\nPostgreSQL 18: Includes PostGIS 3.6.4 (no raster or topology).")
    }

    /// A note is shown whole up to the 120 characters a recipe may use.
    func testServiceTableShowsAWhole120CharacterNote() {
        let note = "Search indexes are tied to Meilisearch 1.57; export a dump before changing version. "
            + String(repeating: "x", count: 36)
        XCTAssertEqual(note.count, 120)
        let noted = ServiceStatus(id: "meilisearch-1-57", name: "Meilisearch 1.57", kind: "meilisearch", version: "1.57.0",
                                  displayName: "Meilisearch", state: .running, ports: ["main": 7700], env: [],
                                  openURL: nil, dataPath: "/d", autostart: true, mainPort: 7700, notes: [note])
        XCTAssertTrue(Messages.serviceTable([noted]).hasSuffix("\n\nMeilisearch 1.57: \(note)"),
                      Messages.serviceTable([noted]))
    }

    /// `paddock service add` prints the .env lines the status has (never a secret's) and, for each secret, a
    /// comment that is safe to paste and says how to get it.
    func testAddedEnvLinesLeaveSecretsOut() {
        let status = ServiceStatus(id: "meilisearch-1-57", name: "Meilisearch 1.57", kind: "meilisearch", version: "1.57.0",
                                   displayName: "Meilisearch", state: .running, ports: ["main": 7700],
                                   env: ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:7700"],
                                   openURL: nil, dataPath: "/d", autostart: true, mainPort: 7700,
                                   secretEnvNames: ["MEILISEARCH_KEY"])
        XCTAssertEqual(Messages.addedEnvLines(status),
                       ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:7700",
                        "# MEILISEARCH_KEY: run \"paddock service env meilisearch-1-57\""])
        let plain = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1", displayName: "Mail", state: .running,
                                  ports: [:], env: ["MAIL_PORT=1025"], openURL: nil, dataPath: "/d", autostart: true,
                                  mainPort: nil)
        XCTAssertEqual(Messages.addedEnvLines(plain), ["MAIL_PORT=1025"])
    }

    func testStates() {
        XCTAssertEqual([ServiceState.running, .starting, .stopped, .crashed, .portInUse(holder: "Herd"),
                        .unavailable(reason: "no PHP")].map(Messages.serviceState),
                       ["running", "starting", "stopped", "crashed", "port in use by Herd", "unavailable: no PHP"])
    }

    func testCatalogTable() {
        func series(_ name: String, _ version: String, _ bytes: Int?) -> CatalogSeries {
            CatalogSeries(series: name, version: version, downloadBytes: bytes, needsDownload: true)
        }
        XCTAssertEqual(Messages.catalogTable([
            CatalogEntry(kind: "mail", displayName: "Mail", licence: "MIT", versions: ["1.34.0"], downloadBytes: 11_224_715,
                         series: [series("1", "1.34.0", 11_224_715)]),
            CatalogEntry(kind: "postgres", displayName: "PostgreSQL", licence: "PostgreSQL", versions: ["18.1", "17.6"],
                         downloadBytes: nil, series: [series("18", "18.1", nil), series("17", "17.6", 90_000_000)]),
            CatalogEntry(kind: "reverb", displayName: "Reverb", licence: "MIT", versions: ["1.0"], downloadBytes: 0,
                         series: [series("1", "1.0", 0)]),
        ]), """
            KIND      SERVICE     SERIES  LICENCE     DOWNLOAD
            mail      Mail        1       MIT         11 MB
            postgres  PostgreSQL  18, 17  PostgreSQL  ?
            reverb    Reverb      1       MIT         none
            """)
    }

    /// A series this Mac can't run is listed with the reason, after the table.
    func testCatalogTableSaysWhatCantRunHere() {
        let reason = "PostgreSQL 18 needs macOS 15 or later."
        XCTAssertEqual(Messages.catalogTable([
            CatalogEntry(kind: "postgres", displayName: "PostgreSQL", licence: "PostgreSQL", versions: ["18.1"],
                         downloadBytes: nil, series: [CatalogSeries(series: "18", version: "18.1", downloadBytes: nil,
                                                                    needsDownload: true, unavailableReason: reason)],
                         unavailableReason: reason),
        ]), """
            KIND      SERVICE     SERIES  LICENCE     DOWNLOAD
            postgres  PostgreSQL  18      PostgreSQL  ?

            PostgreSQL 18 needs macOS 15 or later.
            """)
    }

    func testPortHolderIsNamedAndSanitised() {
        XCTAssertEqual(Messages.portHolder([PortHolder(port: 1, pid: 5, command: "nc", ownedByCurrentUser: true)]),
                       "nc (pid 5)")
        XCTAssertEqual(Messages.portHolder([PortHolder(port: 1, pid: 9, command: "nginx", ownedByCurrentUser: false,
                                                       executablePath: "/Applications/Herd.app/Contents/Resources/nginx")]),
                       "Herd")
        XCTAssertEqual(Messages.portHolder([PortHolder(port: 1, pid: 7, command: "evil\u{1B}[31m\nname",
                                                       ownedByCurrentUser: true)]),
                       "evil (pid 7)", "escape sequences and everything after a line break are dropped")
        XCTAssertEqual(Messages.portHolder([]), "another program")
    }

    func testServiceErrors() {
        XCTAssertEqual(Messages.serviceError(.unknownKind("nope", available: ["mail", "postgres"])),
                       "Paddock has no service called \"nope\". Available: mail, postgres.")
        XCTAssertEqual(Messages.serviceError(.unknownService("x")), "No service named \"x\". See: paddock service list")
        XCTAssertEqual(Messages.serviceError(.portInUse(name: "Mail", port: 1025, holder: "Herd")),
                       "Mail can't start: port 1025 is in use by Herd.")
        XCTAssertEqual(Messages.serviceError(.installFailed(name: "Mail", reason: .checksumMismatch(file: "m.tar.gz"))),
                       "Couldn't install Mail: the download m.tar.gz isn't the file Paddock expects (checksum mismatch).")
        XCTAssertEqual(Messages.serviceError(.notReady(name: "Mail", log: "boom")),
                       "Mail didn't start. The end of its log:\nboom")
        XCTAssertEqual(Messages.serviceError(.notLoopback(name: "Fake", address: "*:4000")),
                       "Fake tried to listen on *:4000, which is not this Mac only. Paddock stopped it.")
        XCTAssertEqual(Messages.serviceError(.initialiseTimedOut(name: "Fake", seconds: 120, output: "")),
                       "Setting up Fake took longer than 120 seconds, so Paddock stopped it.")
        XCTAssertEqual(Messages.serviceError(.updateFailed(name: "Fake", version: "1.1", previous: "1.0", log: "x")),
                       "Fake 1.1 didn't start, so Paddock went back to 1.0. The end of its log:\nx")
        XCTAssertEqual(Messages.serviceError(.cancelled(name: "mail")),
                       "Adding mail was cancelled because Paddock is shutting down.")
        XCTAssertEqual(Messages.existingServiceData("Mail"), "Found existing data for Mail; using it.")
        XCTAssertEqual(Messages.serviceError(.needsNewerMacOS(name: "PostgreSQL 18", minimum: "15.0")),
                       "PostgreSQL 18 needs macOS 15 or later.")
        XCTAssertEqual(Messages.serviceError(.needsNewerMacOS(name: "Sample", minimum: "14.2")),
                       "Sample needs macOS 14.2 or later.")
        XCTAssertEqual(Messages.serviceError(.noAction(name: "Mail", action: RecipeAction.createDatabase)),
                       "Mail doesn't have databases.")
        XCTAssertEqual(Messages.serviceError(.invalidParameter(parameter: "database", value: "a-b")),
                       "Database names can use letters, numbers and underscores.")
        XCTAssertEqual(Messages.serviceError(.actionFailed(name: "PostgreSQL 18", action: RecipeAction.createDatabase,
                                                           output: "boom")),
                       "Couldn't create the database in PostgreSQL 18:\nboom")
        XCTAssertEqual(Messages.serviceError(.notRunning(name: "PostgreSQL 18", id: "postgres-18")),
                       "PostgreSQL 18 isn't running. Start it with: paddock service start postgres-18")
        XCTAssertEqual(Messages.databaseCreated("shop", in: "PostgreSQL 18", alreadyExisted: false),
                       "Created database shop in PostgreSQL 18.")
        XCTAssertEqual(Messages.databaseCreated("shop", in: "PostgreSQL 18", alreadyExisted: true),
                       "shop already exists in PostgreSQL 18.")
    }
}
