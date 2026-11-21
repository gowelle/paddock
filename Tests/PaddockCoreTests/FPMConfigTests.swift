import XCTest
@testable import PaddockCore

final class FPMConfigTests: XCTestCase {
    private let v = PHPVersion("8.4")!
    private let paths = Paths(home: URL(fileURLWithPath: "/tmp/pdk-home", isDirectory: true))

    func testRenderContainsPoolValues() {
        let text = FPMConfig.render(version: v, paths: paths)
        for line in [
            "listen = \(paths.fpmSocket(v).path)",
            "pm = ondemand",
            "pm.max_children = 10",
            "pm.process_idle_timeout = 60s",
            "error_log = \(paths.log.path)/php-fpm-8.4.log",
            "daemonize = no",
            "php_admin_value[error_log] = \(paths.log.path)/php-8.4.log",
            "pid = \(paths.run.path)/php-fpm-8.4.pid",
            "[global]", "[www]",
        ] {
            XCTAssertTrue(text.contains(line), "missing: \(line)")
        }
        XCTAssertFalse(text.contains("user ="))
        XCTAssertFalse(text.contains("group ="))
    }

    func testDefaultIni() {
        let ini = FPMConfig.defaultIni(version: v, paths: paths)
        for line in [
            "memory_limit = 512M", "upload_max_filesize = 128M", "post_max_size = 128M",
            "max_execution_time = 120", "display_errors = On", "error_reporting = E_ALL",
            "extension_dir = \(paths.phpDir(v).path)/ext",
        ] {
            XCTAssertTrue(ini.contains(line), "missing: \(line)")
        }
        XCTAssertFalse(ini.contains("date.timezone"))
    }

    func testWriteIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-fpm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let p = Paths(home: home)
        let first = try FPMConfig.write(version: v, paths: p)
        let a = try String(contentsOf: first)
        let second = try FPMConfig.write(version: v, paths: p)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.path, p.config.appendingPathComponent("fpm/8.4.conf").path)
        XCTAssertEqual(try String(contentsOf: second), a)
        XCTAssertEqual(a, FPMConfig.render(version: v, paths: p))
    }
}
