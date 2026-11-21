import XCTest
@testable import PaddockCore

final class FPMTests: XCTestCase {
    func testVendoredFPMStartsWithRenderedConfig() throws {
        let v = PHPVersion("8.5")!
        let fpm = Bundled.resources.appendingPathComponent("php/8.5/default/php-fpm")
        guard FileManager.default.isExecutableFile(atPath: fpm.path) else {
            throw XCTSkip("Vendored php-fpm missing; run Scripts/fetch-vendor.sh")
        }
        // Short path: unix socket paths are limited to ~104 bytes.
        let suffix = String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let home = URL(fileURLWithPath: "/tmp/pdk-\(suffix)", isDirectory: true)
        let paths = Paths(home: home)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: home) }

        let conf = try FPMConfig.write(version: v, paths: paths)
        let ini = paths.phpIni(v)
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(FPMConfig.defaultIni(version: v, paths: paths).utf8).write(to: ini)

        let process = Process()
        process.executableURL = fpm
        process.arguments = ["-y", conf.path, "-c", ini.path, "-F"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let socket = paths.fpmSocket(v).path
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "socket did not appear")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(process.isRunning, "php-fpm exited early")
    }
}
