import Darwin
import XCTest
@testable import PaddockCore

final class EnvFileTests: XCTestCase {
    private func siteFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(".env")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func contents(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8)
    }

    private func env(_ folder: URL) -> URL { folder.appendingPathComponent(".env") }

    func testItWritesTheMergedFileAndKeepsTheFilesPermissions() throws {
        let folder = try siteFolder()
        let file = try write("DB_HOST=old\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let result = try EnvFile.wire(["DB_HOST=127.0.0.1", "DB_PORT=5432"], intoSiteAt: folder.path)
        XCTAssertEqual(try contents(folder), "DB_HOST=127.0.0.1\nDB_PORT=5432\n")
        XCTAssertEqual(result.added, ["DB_PORT"])
        XCTAssertEqual(result.updated, ["DB_HOST"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAMissingEnvFileIsRefusedAndNothingIsCreated() throws {
        let folder = try siteFolder()
        XCTAssertThrowsError(try EnvFile.wire(["A=1"], intoSiteAt: folder.path)) {
            XCTAssertEqual($0 as? EnvFile.Problem, .missing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: env(folder).path))
    }

    func testASymlinkedEnvFileIsRefusedAndItsTargetIsUntouched() throws {
        let folder = try siteFolder()
        let target = folder.appendingPathComponent("real.env")
        try Data("DB_HOST=old\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: env(folder).path, withDestinationPath: "real.env")
        XCTAssertThrowsError(try EnvFile.wire(["DB_HOST=new"], intoSiteAt: folder.path)) {
            XCTAssertEqual($0 as? EnvFile.Problem, .symlink)
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "DB_HOST=old\n")
    }

    func testANonUTF8EnvFileIsRefusedAndLeftAlone() throws {
        let folder = try siteFolder()
        let bytes = Data([0x41, 0x3D, 0xFF, 0x0A])
        try bytes.write(to: env(folder))
        XCTAssertThrowsError(try EnvFile.wire(["B=2"], intoSiteAt: folder.path)) {
            XCTAssertEqual($0 as? EnvFile.Problem, .notUTF8)
        }
        XCTAssertEqual(try Data(contentsOf: env(folder)), bytes)
    }

    func testNothingToDoWritesNothing() throws {
        let folder = try siteFolder()
        let file = try write("A=1\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let result = try EnvFile.wire(["A=1"], intoSiteAt: folder.path)
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, [])
        XCTAssertEqual(try contents(folder), "A=1\n")
    }

    func testAnUnreadableEnvFileReportsTheSystemsSentence() throws {
        try XCTSkipIf(getuid() == 0, "root reads anything")
        let folder = try siteFolder()
        let file = try write("A=1\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try EnvFile.wire(["A=2"], intoSiteAt: folder.path)) {
            guard case .unreadable(let reason)? = $0 as? EnvFile.Problem else {
                return XCTFail("expected unreadable, got \($0)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testAWriteIntoAReadOnlyFolderReportsUnwritable() throws {
        try XCTSkipIf(getuid() == 0, "root writes anywhere")
        let folder = try siteFolder()
        try write("A=1\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try EnvFile.wire(["A=2"], intoSiteAt: folder.path)) {
            guard case .unwritable(let reason)? = $0 as? EnvFile.Problem else {
                return XCTFail("expected unwritable, got \($0)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testEachProblemBecomesItsSentence() {
        XCTAssertEqual(Messages.envWiringProblem(.missing, host: "shop.test"),
                       "shop.test has no .env. Create one from .env.example first; "
                       + "Paddock won't write secrets into a new file.")
        XCTAssertEqual(Messages.envWiringProblem(.symlink, host: "shop.test"),
                       "shop.test's .env is a symlink; Paddock won't write through it.")
        XCTAssertEqual(Messages.envWiringProblem(.notUTF8, host: "shop.test"),
                       "shop.test's .env isn't UTF-8; Paddock left it alone.")
        XCTAssertEqual(Messages.envWiringProblem(.unreadable("No permission."), host: "shop.test"),
                       "Paddock couldn't read shop.test's .env: No permission.")
        XCTAssertEqual(Messages.envWiringProblem(.unreadable("No permission"), host: "shop.test"),
                       "Paddock couldn't read shop.test's .env: No permission.")
        XCTAssertEqual(Messages.envWiringProblem(.unwritable("Disk full"), host: "shop.test"),
                       "Paddock couldn't write shop.test's .env: Disk full.")
    }
}
