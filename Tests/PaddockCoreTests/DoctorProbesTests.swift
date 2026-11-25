import XCTest
@testable import PaddockCore

final class DoctorProbesTests: XCTestCase {
    private var folder: URL!
    private lazy var site = Site(name: "shop", path: folder.path, kind: .parked, secured: false,
                                 php: PHPVersion(major: 8, minor: 5), pinned: false)

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        folder = base.appendingPathComponent("pdk doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("storage/logs"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: log.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private var log: URL { folder.appendingPathComponent("storage/logs/laravel.log") }

    private func write(_ lines: String...) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log)
    }

    func testAStandardPortIsLeftOutOfTheAddress() {
        XCTAssertEqual(Doctor.siteAddress(site, settings: Settings()).absoluteString, "http://shop.test")
        var secure = site
        secure.secured = true
        XCTAssertEqual(Doctor.siteAddress(secure, settings: Settings()).absoluteString,
                       "https://shop.test")
    }

    func testConfiguredPortsAreUsed() {
        var settings = Settings()
        settings.httpPort = 8080
        settings.httpsPort = 8443
        XCTAssertEqual(Doctor.siteAddress(site, settings: settings).absoluteString,
                       "http://shop.test:8080")
        var secure = site
        secure.secured = true
        XCTAssertEqual(Doctor.siteAddress(secure, settings: settings).absoluteString,
                       "https://shop.test:8443")
    }

    func testNoLogs() {
        XCTAssertEqual(Doctor.logFindingFor(site), .none)
    }

    func testNoErrors() throws {
        try write("[2026-11-25 10:00:00] production.INFO: Everything fine")
        XCTAssertEqual(Doctor.logFindingFor(site), .noErrors(file: "laravel.log"))
    }

    func testTheNewestErrorWins() throws {
        try write("[2026-11-25 10:00:00] production.ERROR: First",
                  "[2026-11-25 10:01:00] production.ERROR: Second")
        XCTAssertEqual(Doctor.logFindingFor(site),
                       .error(file: "laravel.log", line: "[2026-11-25 10:01:00] production.ERROR: Second"))
    }

    func testAnUnreadableLogIsReported() throws {
        try write("[2026-11-25 10:00:00] production.ERROR: Hidden")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)
        XCTAssertEqual(Doctor.logFindingFor(site), .unreadable(file: "laravel.log"))
    }

    func testASymlinkedLogIsNeverRead() throws {
        let outside = folder.appendingPathComponent("outside.log")
        try Data("[2026-11-25 10:00:00] production.ERROR: Outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)
        // The catalog lists regular files only (attributes of the link itself), so the link is never
        // offered to the reader and the error behind it is hidden.
        XCTAssertEqual(Doctor.logFindingFor(site), .none)
    }
}
