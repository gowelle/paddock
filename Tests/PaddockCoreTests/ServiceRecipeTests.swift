import XCTest
@testable import PaddockCore

final class ServiceRecipeTests: XCTestCase {
    static let sampleJSON = """
    {
      "kind": "sample",
      "displayName": "Sample",
      "version": "2.1.0",
      "licence": "MIT",
      "minimumMacOS": "13.0",
      "assets": [{
        "artifact": {"url": "https://example.invalid/sample.tar.gz", "sha256": "abc", "size": 10},
        "archive": "tar.gz", "stripComponents": 1, "installAs": null
      }],
      "initialise": [{"executable": "{bin}/sample", "arguments": ["init", "{data}"], "environment": {}}],
      "start": {"executable": "{bin}/sample", "arguments": ["--port", "{port.main}"],
                "environment": {"HOME": "{data}"}, "stdin": null},
      "ready": {"tcp": {"port": "{port.main}"}},
      "stopSignal": "INT",
      "stopGraceSeconds": 7,
      "ports": [{"name": "main", "preferred": 4000}],
      "socket": "{run}/sample.sock",
      "env": ["SAMPLE_PORT={port.main}"],
      "openURL": null,
      "needsPHP": false
    }
    """

    func testDecodesASampleRecipe() throws {
        let recipe = try JSONDecoder().decode(ServiceRecipe.self, from: Data(Self.sampleJSON.utf8))
        XCTAssertEqual(recipe.kind, "sample")
        XCTAssertEqual(recipe.version, "2.1.0")
        XCTAssertEqual(recipe.assets, [RecipeAsset(
            artifact: Artifact(url: URL(string: "https://example.invalid/sample.tar.gz")!, sha256: "abc", size: 10),
            archive: "tar.gz", stripComponents: 1, installAs: nil)])
        XCTAssertEqual(recipe.initialise, [RecipeCommand(executable: "{bin}/sample", arguments: ["init", "{data}"])])
        XCTAssertEqual(recipe.start.environment, ["HOME": "{data}"])
        XCTAssertEqual(recipe.ready, .tcp(port: "{port.main}"))
        XCTAssertEqual(recipe.stopSignal, "INT")
        XCTAssertEqual(recipe.signalNumber, SIGINT)
        XCTAssertEqual(recipe.stopGraceSeconds, 7)
        XCTAssertEqual(recipe.ports, [RecipePort(name: "main", preferred: 4000)])
        XCTAssertEqual(recipe.socket, "{run}/sample.sock")
        XCTAssertEqual(recipe.env, ["SAMPLE_PORT={port.main}"])
        XCTAssertNil(recipe.openURL)
        XCTAssertFalse(recipe.needsPHP)
        // Round trip.
        XCTAssertEqual(try JSONDecoder().decode(ServiceRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
    }

    func testOptionalFieldsDefault() throws {
        let json = """
        {"kind": "tiny", "displayName": "Tiny", "version": "1", "licence": "MIT",
         "start": {"executable": "/bin/sleep", "arguments": ["5"]},
         "ready": {"http": {"url": "http://127.0.0.1:{port.main}/", "expectStatus": 200}},
         "ports": [{"name": "main", "preferred": 4000}]}
        """
        let recipe = try JSONDecoder().decode(ServiceRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(recipe.assets, [])
        XCTAssertEqual(recipe.initialise, [])
        XCTAssertEqual(recipe.env, [])
        XCTAssertEqual(recipe.stopSignal, "TERM")
        XCTAssertEqual(recipe.signalNumber, SIGTERM)
        XCTAssertEqual(recipe.stopGraceSeconds, 10)
        XCTAssertNil(recipe.socket)
        XCTAssertNil(recipe.minimumMacOS)
        XCTAssertFalse(recipe.needsPHP)
        XCTAssertEqual(recipe.start.environment, [:])
        XCTAssertNil(recipe.start.stdin)
        XCTAssertEqual(recipe.ready, .http(url: "http://127.0.0.1:{port.main}/", expectStatus: 200))
        XCTAssertEqual(Readiness.deadline, 30)
    }

    // MARK: - Catalog

    private func recipe(_ kind: String, _ version: String, name: String? = nil, size: Int? = 5) -> ServiceRecipe {
        ServiceRecipe(kind: kind, displayName: name ?? kind.capitalized, version: version, licence: "MIT",
                      assets: [RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/\(kind)")!,
                                                              sha256: "00", size: size),
                                           archive: "binary", stripComponents: 0, installAs: kind)],
                      start: RecipeCommand(executable: "{bin}/\(kind)"),
                      ready: .tcp(port: "{port.main}"),
                      ports: [RecipePort(name: "main", preferred: 4000)])
    }

    func testCatalogLookupPicksNewestVersionWhenNoneIsGiven() {
        let catalog = ServiceCatalog(recipes: [recipe("postgres", "9.6"), recipe("postgres", "18"),
                                               recipe("postgres", "16.4"), recipe("mail", "1.34.0")])
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: nil)?.version, "18")
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: "16.4")?.version, "16.4")
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: "16")?.version, "16.4", "a major version picks its newest")
        XCTAssertNil(catalog.recipe(kind: "postgres", version: "15"))
        XCTAssertEqual(catalog.recipe(kind: "MAIL", version: nil)?.version, "1.34.0", "kinds match case-insensitively")
        XCTAssertNil(catalog.recipe(kind: "redis", version: nil))
    }

    func testCatalogKindsListVersionsNewestFirstAndDownloadSize() {
        let catalog = ServiceCatalog(recipes: [recipe("postgres", "16", name: "PostgreSQL"),
                                               recipe("postgres", "18", name: "PostgreSQL", size: 92),
                                               recipe("mail", "1.34.0", name: "Mail", size: nil)])
        XCTAssertEqual(catalog.kinds().map(\.kind), ["mail", "postgres"])
        let postgres = catalog.kinds()[1]
        XCTAssertEqual(postgres.displayName, "PostgreSQL")
        XCTAssertEqual(postgres.versions, ["18", "16"])
        XCTAssertEqual(postgres.downloadBytes, 92)
        XCTAssertEqual(postgres.licence, "MIT")
        XCTAssertNil(catalog.kinds()[0].downloadBytes, "unknown when an asset's size is unknown")
    }

    func testVersionOrderingIsNumeric() {
        XCTAssertTrue(ServiceCatalog.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(ServiceCatalog.isNewer("18", than: "9.6"))
        XCTAssertFalse(ServiceCatalog.isNewer("1.2", than: "1.2"))
    }

    func testBundledCatalogDecodesAndHasMail() throws {
        let catalog = try ServiceCatalog.bundled()
        let mail = try XCTUnwrap(catalog.recipe(kind: "mail", version: nil))
        XCTAssertEqual(mail.displayName, "Mail")
        XCTAssertEqual(mail.ports.map(\.name), ["smtp", "http"])
        XCTAssertEqual(mail.ports.map(\.preferred), [1025, 8025])
        XCTAssertEqual(mail.licence, "MIT")
        XCTAssertEqual(mail.assets.count, 1)
        XCTAssertEqual(mail.assets[0].artifact.sha256.count, 64)
        XCTAssertEqual(mail.env, ["MAIL_MAILER=smtp", "MAIL_HOST=127.0.0.1", "MAIL_PORT={port.smtp}",
                                  "MAIL_USERNAME=null", "MAIL_PASSWORD=null", "MAIL_ENCRYPTION=null"])
        XCTAssertEqual(mail.openURL, "http://127.0.0.1:{port.http}")
        for recipe in catalog.recipes {
            XCTAssertTrue(ServiceInstance.isValidID(recipe.kind), "kind \(recipe.kind) is a valid id")
            XCTAssertTrue(["TERM", "INT", "QUIT"].contains(recipe.stopSignal), recipe.kind)
            XCTAssertTrue(recipe.assets.allSatisfy { ["tar.gz", "tar.xz", "zip", "binary"].contains($0.archive) })
        }
    }

    /// The catalog a daemon uses: a development home may name its own file (tests); a real home never.
    func testDaemonCatalogOverrideOnlyInDevelopmentHomes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [recipe("fake", "1")])).write(to: file)

        let development = ServiceCatalog.forDaemon(environment: ["PADDOCK_HOME": "/tmp/x",
                                                                 "PADDOCK_SERVICES_CATALOG": file.path])
        XCTAssertEqual(development.recipes.map(\.kind), ["fake"])
        let real = ServiceCatalog.forDaemon(environment: ["PADDOCK_SERVICES_CATALOG": file.path])
        XCTAssertNil(real.recipe(kind: "fake", version: nil))
        XCTAssertNotNil(real.recipe(kind: "mail", version: nil))
    }
}
