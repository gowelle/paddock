import Darwin
import XCTest
@testable import PaddockCore

/// An instance's secrets: random, made once, kept owner-only, never replaced when the file is odd.
final class ServiceSecretsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-secrets-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private var config: URL { folder.appendingPathComponent("config") }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testGeneratedValuesAreRandomURLSafeBase64() throws {
        let values = try (0..<20).map { _ in try ServiceSecrets.generate(bytes: 32) }
        XCTAssertEqual(Set(values).count, 20)
        for value in values {
            XCTAssertEqual(value.count, 43, "32 bytes, unpadded")
            XCTAssertTrue(ServiceSecrets.isWellFormedValue(value), value)
            XCTAssertNil(value.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), value)
        }
        XCTAssertEqual(try ServiceSecrets.generate(bytes: 16).count, 22)
    }

    func testMadeOnceKeptOwnerOnlyAndAddedWhenTheRecipeGainsOne() throws {
        let key = RecipeSecret(name: "master_key", bytes: 32)
        let first = try ServiceSecrets.ensure([key], in: config)
        XCTAssertEqual(Array(first.keys), ["master_key"])
        XCTAssertEqual(try mode(config), 0o700)
        XCTAssertEqual(try mode(ServiceSecrets.file(in: config)), 0o600)
        XCTAssertEqual(try ServiceSecrets.ensure([key], in: config), first, "kept as it is")
        XCTAssertEqual(try ServiceSecrets.load(from: config), first)
        let more = try ServiceSecrets.ensure([key, RecipeSecret(name: "other", bytes: 16)], in: config)
        XCTAssertEqual(more["master_key"], first["master_key"])
        XCTAssertEqual(more["other"]?.count, 22)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.path), [ServiceSecrets.fileName],
                       "no temporary file left")
    }

    func testAFileItCantUseIsNeverReplaced() throws {
        let key = RecipeSecret(name: "master_key", bytes: 32)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let file = ServiceSecrets.file(in: config)
        for bad in [#"{"master_key": "has a\nnewline in it and is long"}"#, "not json", #"{"master_key": "short"}"#] {
            try Data(bad.utf8).write(to: file)
            XCTAssertThrowsError(try ServiceSecrets.ensure([key], in: config)) {
                XCTAssertEqual($0 as? ServiceSecretsError, .damaged(path: file.path))
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), bad, "left alone")
        }
        try FileManager.default.removeItem(at: file)
        let elsewhere = folder.appendingPathComponent("elsewhere.json")
        try Data(#"{"master_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ServiceSecrets.load(from: config)) {
            XCTAssertEqual($0 as? ServiceSecretsError, .damaged(path: file.path), "a symlink is not followed")
        }
    }
}
