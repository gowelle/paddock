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

    func testStates() {
        XCTAssertEqual([ServiceState.running, .starting, .stopped, .crashed, .portInUse(holder: "Herd"),
                        .unavailable(reason: "no PHP")].map(Messages.serviceState),
                       ["running", "starting", "stopped", "crashed", "port in use by Herd", "unavailable: no PHP"])
    }

    func testCatalogTable() {
        XCTAssertEqual(Messages.catalogTable([
            CatalogEntry(kind: "mail", displayName: "Mail", licence: "MIT", versions: ["1.34.0"], downloadBytes: 11_224_715),
            CatalogEntry(kind: "postgres", displayName: "PostgreSQL", licence: "PostgreSQL", versions: ["18", "17"],
                         downloadBytes: nil),
            CatalogEntry(kind: "reverb", displayName: "Reverb", licence: "MIT", versions: ["1"], downloadBytes: 0),
        ]), """
            KIND      SERVICE     VERSIONS  LICENCE     DOWNLOAD
            mail      Mail        1.34.0    MIT         11 MB
            postgres  PostgreSQL  18, 17    PostgreSQL  ?
            reverb    Reverb      1         MIT         none
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
        XCTAssertEqual(Messages.serviceError(.cancelled(name: "mail")),
                       "Adding mail was cancelled because Paddock is shutting down.")
        XCTAssertEqual(Messages.existingServiceData("Mail"), "Found existing data for Mail; using it.")
    }
}
