import XCTest
@testable import PaddockCore

final class PHPResolverTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var sites: URL!
    private let v84 = PHPVersion("8.4")!
    private let v85 = PHPVersion("8.5")!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pdk-resolver-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        sites = root.appendingPathComponent("sites", isDirectory: true)
        for folder in ["pinned/app/Http", "plain"] {
            try FileManager.default.createDirectory(
                at: sites.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ v: PHPVersion) throws {
        let dir = paths.phpDir(v)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let file = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    private func state(default d: PHPVersion?, pins: [String: PHPVersion] = [:]) throws {
        let parked = sites.path
        try StateStore(paths: paths).update {
            $0 = State(parked: [parked], phpPins: pins, defaultPHP: d)
        }
    }

    func testPinnedSiteAndItsSubdirectoriesResolveToThePin() throws {
        try install(v84); try install(v85)
        try state(default: v85, pins: ["pinned": v84])
        let resolver = PHPResolver(paths: paths)
        XCTAssertEqual(resolver.version(forDirectory: sites.appendingPathComponent("pinned").path), v84)
        XCTAssertEqual(resolver.version(forDirectory: sites.appendingPathComponent("pinned/app/Http").path), v84)
    }

    func testDefaultElsewhere() throws {
        try install(v84); try install(v85)
        try state(default: v84, pins: ["pinned": v85])
        let resolver = PHPResolver(paths: paths)
        XCTAssertEqual(resolver.version(forDirectory: sites.appendingPathComponent("plain").path), v84)
        XCTAssertEqual(resolver.version(forDirectory: root.path), v84)
    }

    func testNilWhenNothingInstalled() throws {
        try state(default: v85)
        let resolver = PHPResolver(paths: paths)
        XCTAssertNil(resolver.version(forDirectory: root.path))
        XCTAssertNil(resolver.binary(forDirectory: root.path))
    }

    func testNoStoredDefaultUsesNewestInstalled() throws {
        try install(v84); try install(v85)
        try state(default: nil)
        XCTAssertEqual(PHPResolver(paths: paths).version(forDirectory: root.path), v85)
    }

    func testUninstalledPinOrDefaultFallsBackToNewestInstalled() throws {
        try install(v84)
        try state(default: v85, pins: ["pinned": PHPVersion("8.3")!])
        let resolver = PHPResolver(paths: paths)
        XCTAssertEqual(resolver.version(forDirectory: sites.appendingPathComponent("pinned").path), v84)
        XCTAssertEqual(resolver.version(forDirectory: root.path), v84)
    }

    func testBinaryIsTheVersionsPhp() throws {
        try install(v84)
        try state(default: v84)
        XCTAssertEqual(PHPResolver(paths: paths).binary(forDirectory: root.path),
                       paths.phpDir(v84).appendingPathComponent("php"))
    }

    func testNoStateFileStillResolves() throws {
        try install(v85)
        XCTAssertEqual(PHPResolver(paths: paths).version(forDirectory: root.path), v85)
    }
}
