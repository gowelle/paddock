import XCTest
@testable import PaddockCore

final class ServiceRecipeTests: XCTestCase {
    static let sampleJSON = """
    {
      "kind": "sample",
      "displayName": "Sample",
      "version": "2.1.0",
      "series": "2",
      "seriesInID": false,
      "licence": "MIT",
      "minimumMacOS": "13.0",
      "assets": [{
        "artifact": {"url": "https://example.invalid/sample.tar.gz", "sha256": "abc", "size": 10},
        "archive": "tar.gz", "stripComponents": 1, "installAs": null
      }],
      "initialise": [{"executable": "{bin}/sample", "arguments": ["init", "{data}"], "environment": {}}],
      "start": {"executable": "{bin}/sample",
                "arguments": ["--port", "{port.main}", {"ifSocket": ["--socket", "{socket}"]}],
                "environment": {"HOME": "{data}"}, "stdin": null},
      "configFiles": [{"path": "{config}/sample.conf", "contents": "port = {port.main}\\n"}],
      "readyTimeoutSeconds": 45,
      "initialiseTimeoutSeconds": 300,
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
        XCTAssertEqual(recipe.series, "2")
        XCTAssertFalse(recipe.seriesInID)
        XCTAssertEqual(recipe.start.arguments, ["--port", "{port.main}", .ifSocket(["--socket", "{socket}"])])
        XCTAssertEqual(recipe.configFiles, [RecipeFile(path: "{config}/sample.conf", contents: "port = {port.main}\n")])
        XCTAssertEqual(recipe.readyTimeout, 45)
        XCTAssertEqual(recipe.initialiseTimeout, 300)
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
        {"kind": "tiny", "displayName": "Tiny", "version": "1", "series": "1", "licence": "MIT",
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
        XCTAssertTrue(recipe.seriesInID)
        XCTAssertEqual(recipe.configFiles, [])
        XCTAssertEqual(recipe.readyTimeout, 30)
        XCTAssertEqual(recipe.initialiseTimeout, 120)
    }

    // MARK: - Catalog

    private func recipe(_ kind: String, _ version: String, series: String? = nil, name: String? = nil,
                        size: Int? = 5) -> ServiceRecipe {
        ServiceRecipe(kind: kind, displayName: name ?? kind.capitalized, version: version,
                      series: series ?? String(version.split(separator: ".")[0]), licence: "MIT",
                      assets: [RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/\(kind)")!,
                                                              sha256: "00", size: size),
                                           archive: "binary", stripComponents: 0, installAs: kind)],
                      start: RecipeCommand(executable: "{bin}/\(kind)"),
                      ready: .tcp(port: "{port.main}"),
                      ports: [RecipePort(name: "main", preferred: 4000)])
    }

    func testCatalogLookupPicksNewestVersionWhenNoneIsGiven() {
        let catalog = ServiceCatalog(recipes: [recipe("postgres", "9.6"), recipe("postgres", "18.0"),
                                               recipe("postgres", "16.4"), recipe("postgres", "16.10"),
                                               recipe("mysql", "8.4.11", series: "8.4"), recipe("mysql", "8.0.46", series: "8.0"),
                                               recipe("mail", "1.34.0")])
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: nil)?.version, "18.0")
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: "16.4")?.version, "16.4")
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: "16")?.version, "16.10", "a series picks its newest patch")
        XCTAssertEqual(catalog.recipe(kind: "postgres", series: "16")?.version, "16.10")
        XCTAssertEqual(catalog.recipe(kind: "mysql", version: "8.4")?.version, "8.4.11")
        XCTAssertNil(catalog.recipe(kind: "mysql", series: "9.7"))
        XCTAssertNil(catalog.recipe(kind: "postgres", version: "15"))
        XCTAssertEqual(catalog.recipe(kind: "MAIL", version: nil)?.version, "1.34.0", "kinds match case-insensitively")
        XCTAssertNil(catalog.recipe(kind: "redis", version: nil))
    }

    func testCatalogKindsListVersionsNewestFirstAndDownloadSize() {
        let catalog = ServiceCatalog(recipes: [recipe("postgres", "16.1", name: "PostgreSQL"),
                                               recipe("postgres", "16.2", name: "PostgreSQL", size: 90),
                                               recipe("postgres", "18.1", name: "PostgreSQL", size: 92),
                                               recipe("mail", "1.34.0", name: "Mail", size: nil)])
        XCTAssertEqual(catalog.kinds().map(\.kind), ["mail", "postgres"])
        let postgres = catalog.kinds()[1]
        XCTAssertEqual(postgres.displayName, "PostgreSQL")
        XCTAssertEqual(postgres.versions, ["18.1", "16.2", "16.1"])
        XCTAssertEqual(postgres.series, [CatalogSeries(series: "18", version: "18.1", downloadBytes: 92, needsDownload: true),
                                         CatalogSeries(series: "16", version: "16.2", downloadBytes: 90, needsDownload: true)])
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
        XCTAssertEqual(mail.series, "1")
        XCTAssertFalse(mail.seriesInID, "one Mail line: its id stays mail")
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

    /// PostgreSQL 18, 17 and 16 from theseus-rs, each pinned to one archive; the integration tests run them.
    func testBundledCatalogHasPostgreSQL18To16() throws {
        let catalog = try ServiceCatalog.bundled()
        XCTAssertEqual(catalog.recipes(of: "postgres").map(\.version), ["18.7.0", "17.12.0", "16.16.0"])
        XCTAssertEqual(catalog.recipe(kind: "postgres", version: nil)?.series, "18", "the newest by default")
        for recipe in catalog.recipes(of: "postgres") {
            let label = recipe.version
            XCTAssertEqual(recipe.displayName, "PostgreSQL")
            XCTAssertEqual(recipe.series, String(recipe.version.prefix(2)))
            XCTAssertTrue(recipe.seriesInID, "postgres-18, PostgreSQL 18")
            XCTAssertEqual(recipe.licence, "PostgreSQL")
            XCTAssertEqual(recipe.minimumMacOS, "15.0", "LC_BUILD_VERSION minos of every binary in the archives")
            XCTAssertEqual(recipe.assets.count, 2, "PostgreSQL, then Paddock's PostGIS add-on over it")
            let addOn = recipe.assets[1]
            XCTAssertEqual(addOn.artifact.url.absoluteString,
                           "paddock-builds://postgis-3.6.4-pg\(recipe.series)-macos-x86_64.tar.gz")
            XCTAssertEqual(addOn.artifact.sha256.count, 64)
            XCTAssertEqual(addOn.archive, "tar.gz")
            XCTAssertEqual(addOn.stripComponents, 0)
            XCTAssertEqual(recipe.notes, ["Includes PostGIS 3.6.4 (no raster or topology)."])
            let asset = try XCTUnwrap(recipe.assets.first)
            XCTAssertEqual(asset.artifact.url.absoluteString,
                           "https://github.com/theseus-rs/postgresql-binaries/releases/download/\(label)/"
                           + "postgresql-\(label)-x86_64-apple-darwin.tar.gz")
            XCTAssertEqual(asset.artifact.sha256.count, 64)
            XCTAssertNotNil(asset.artifact.size)
            XCTAssertEqual(asset.archive, "tar.gz")
            XCTAssertEqual(asset.stripComponents, 1)
            XCTAssertEqual(recipe.initialise.map(\.executable), ["{bin}/bin/initdb"])
            XCTAssertEqual(recipe.start.executable, "{bin}/bin/postgres")
            XCTAssertTrue(recipe.start.arguments.contains("listen_addresses=127.0.0.1"), label)
            XCTAssertTrue(recipe.start.arguments.contains("unix_socket_directories={socketDir}"), label)
            XCTAssertEqual(recipe.ready, .command(RecipeCommand(executable: "{bin}/bin/pg_isready",
                                                                arguments: ["--host=127.0.0.1", "--port={port.main}",
                                                                            "--quiet"])),
                           "ready means accepting connections, not just a listening port")
            XCTAssertEqual(recipe.stopSignal, "INT", "fast shutdown")
            XCTAssertEqual(recipe.stopGraceSeconds, 60, "a fast shutdown ends with a checkpoint")
            XCTAssertEqual(recipe.lockFiles, ["{data}/postmaster.pid", "{run}/.s.PGSQL.{port.main}.lock"])
            XCTAssertEqual(recipe.ports, [RecipePort(name: "main", preferred: 5432)])
            XCTAssertEqual(recipe.socket, "{run}/.s.PGSQL.{port.main}")
            XCTAssertEqual(recipe.env, ["DB_CONNECTION=pgsql", "DB_HOST=127.0.0.1", "DB_PORT={port.main}",
                                        "DB_DATABASE=laravel", "DB_USERNAME=root", "DB_PASSWORD="])
            XCTAssertNil(recipe.openURL)
            XCTAssertEqual(recipe.configFiles.map(\.path), ["{config}/pg_hba.conf"])
            let rules = recipe.configFiles[0].contents.split(separator: "\n").filter { !$0.hasPrefix("#") }
                .map { $0.split(separator: " ").joined(separator: " ") }
            XCTAssertEqual(rules, ["local all all trust", "host all all 127.0.0.1/32 trust", "host all all ::1/128 trust"],
                           "trust for this Mac only, nothing else")
            let create = try XCTUnwrap(recipe.actions[RecipeAction.createDatabase])
            XCTAssertEqual(create.command.executable, "{bin}/bin/createdb")
            XCTAssertEqual(create.parameters, [RecipeParameter(name: "database", pattern: "^[A-Za-z0-9_]{1,63}$")])
        }
    }

    /// Every one of Paddock's own builds the catalog names is in Scripts/versions.lock with the same checksum,
    /// so fetch-vendor.sh checks it and bundle.sh ships it.
    func testTheCatalogsOwnBuildsAreInTheLock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try String(contentsOf: root.appendingPathComponent("Scripts/versions.lock"), encoding: .utf8)
        let lines = lock.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        let builds = try ServiceCatalog.bundled().recipes.flatMap { recipe in
            recipe.assets.filter { $0.artifact.url.scheme == BuildSource.scheme }.map { (recipe, $0) }
        }
        XCTAssertEqual(builds.count, 4, "the PostGIS add-on of each PostgreSQL series, and Valkey")
        for (recipe, asset) in builds {
            let name = recipe.kind == "redis" ? "valkey" : "postgis-pg\(recipe.series)"
            XCTAssertEqual(lines.first { $0.first == name }, [name, asset.artifact.url.absoluteString, asset.artifact.sha256])
        }
    }

    /// Redis is Valkey, built by Paddock (Scripts/build-valkey.sh) and shipped in the app; one line, id redis.
    func testBundledCatalogHasRedisAsValkey() throws {
        let recipes = try ServiceCatalog.bundled().recipes(of: "redis")
        XCTAssertEqual(recipes.map(\.version), ["9.1.4"], "not 9.2: its RDB format 81 can never go back to 9.1")
        let redis = try XCTUnwrap(recipes.first)
        XCTAssertEqual(redis.displayName, "Redis (Valkey)")
        XCTAssertEqual(redis.series, "9", "data files are compatible within a Valkey major")
        XCTAssertFalse(redis.seriesInID, "its id stays redis")
        XCTAssertEqual(redis.licence, "BSD-3-Clause")
        XCTAssertEqual(redis.minimumMacOS, "13.0", "LC_BUILD_VERSION minos of valkey-server and valkey-cli")
        XCTAssertEqual(redis.assets.map(\.artifact.url.absoluteString), ["paddock-builds://valkey-9.1.4-macos-x86_64.tar.gz"])
        XCTAssertEqual(redis.assets.map(\.archive), ["tar.gz"])
        XCTAssertEqual(redis.assets.map(\.stripComponents), [0])
        XCTAssertEqual(redis.initialise, [])
        XCTAssertEqual(redis.start, RecipeCommand(executable: "{bin}/valkey-server", arguments: ["{config}/valkey.conf"]))
        XCTAssertEqual(redis.ready, .command(RecipeCommand(executable: "{bin}/valkey-cli",
                                                           arguments: ["-h", "127.0.0.1", "-p", "{port.main}", "-e", "ping"])),
                       "-e: an error reply such as LOADING is a failure, not a PONG")
        XCTAssertEqual(redis.stopSignal, "TERM")
        XCTAssertEqual(redis.stopGraceSeconds, 30, "time to write the AOF and RDB on shutdown")
        XCTAssertEqual(redis.ports, [RecipePort(name: "main", preferred: 6379)])
        XCTAssertEqual(redis.socket, "{run}/redis.sock")
        XCTAssertEqual(redis.lockFiles, [], "Valkey's pidfile never blocks a restart")
        XCTAssertEqual(redis.env, ["REDIS_CLIENT=phpredis", "REDIS_HOST=127.0.0.1", "REDIS_PORT={port.main}",
                                   "REDIS_PASSWORD=null"])
        XCTAssertNil(redis.openURL)
        XCTAssertEqual(redis.notes, ["Valkey 9.1.4, a Redis-compatible server."])
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 10, "recipes gained logHints: the build number moves on")
        XCTAssertEqual(redis.logHints, [RecipeLogHint(contains: "Can't handle RDB format version",
                                                      hint: "Its data was written by a newer Valkey, which this version "
                                                          + "can't read; Paddock left the data as it is.")])
        XCTAssertEqual(redis.configFiles.map(\.path), ["{config}/valkey.conf"])
        let lines = redis.configFiles[0].contents.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        for line in ["bind 127.0.0.1 -::1", "port {port.main}", "protected-mode yes", "daemonize no",
                     "dir \"{data}\"", "appendonly yes", "appendfsync everysec", "dbfilename \"dump.rdb\"",
                     "appenddirname \"appendonlydir\"", "pidfile \"{run}/valkey.pid\"", "unixsocket \"{socket}\"",
                     "unixsocketperm 700", "logfile \"\"", "shutdown-on-sigterm force"] {
            XCTAssertTrue(lines.contains(line), "valkey.conf has \(line)")
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("requirepass") || $0.hasPrefix("include") })
    }

    /// Meilisearch's official Intel binary; series at the minor level, since its database is tied to it.
    func testBundledCatalogHasMeilisearch() throws {
        let recipes = try ServiceCatalog.bundled().recipes(of: "meilisearch")
        XCTAssertEqual(recipes.map(\.version), ["1.57.0"])
        let meili = try XCTUnwrap(recipes.first)
        XCTAssertEqual(meili.displayName, "Meilisearch")
        XCTAssertEqual(meili.series, "1.57")
        XCTAssertTrue(meili.seriesInID, "meilisearch-1-57")
        XCTAssertEqual(meili.licence, "MIT")
        XCTAssertEqual(meili.minimumMacOS, "10.12", "the binary's LC_VERSION_MIN_MACOSX")
        let asset = try XCTUnwrap(meili.assets.first)
        XCTAssertEqual(meili.assets.count, 1)
        XCTAssertEqual(asset.artifact.url.absoluteString,
                       "https://github.com/meilisearch/meilisearch/releases/download/v1.57.0/meilisearch-macos-amd64")
        XCTAssertEqual(asset.artifact.sha256, "253ecf09ab119847af7dcc9ebdb233cbe5d612bfe73925008ee87f7c5572ebd5")
        XCTAssertEqual(asset.artifact.size, 351390264)
        XCTAssertEqual(asset.archive, "binary")
        XCTAssertEqual(asset.installAs, "meilisearch")
        XCTAssertEqual(meili.start.executable, "{bin}/meilisearch")
        XCTAssertEqual(meili.start.arguments, [
            "--config-file-path", "{config}/meilisearch.toml", "--http-addr", "127.0.0.1:{port.main}",
            "--db-path", "{data}/data.ms", "--dump-dir", "{data}/dumps", "--snapshot-dir", "{data}/snapshots",
            "--no-analytics", "--env", "development", "--upgrade-db"])
        XCTAssertFalse(meili.start.arguments.contains("--master-key"), "no master key in development, loopback only")
        XCTAssertEqual(meili.ready, .http(url: "http://127.0.0.1:{port.main}/health", expectStatus: 200))
        XCTAssertEqual(meili.stopSignal, "TERM")
        XCTAssertEqual(meili.ports, [RecipePort(name: "main", preferred: 7700)])
        XCTAssertNil(meili.socket)
        XCTAssertEqual(meili.env, ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:{port.main}",
                                   "MEILISEARCH_KEY="])
        XCTAssertEqual(meili.openURL, "http://127.0.0.1:{port.main}")
        XCTAssertEqual(meili.configFiles.map(\.path), ["{config}/meilisearch.toml"])
        XCTAssertEqual(meili.notes, ["Search indexes are tied to Meilisearch 1.57; export a dump before changing version."])
    }

    /// Readiness keeps its JSON form for the existing kinds, and a command is the command itself.
    func testReadinessCoding() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Readiness.self, from: Data(#"{"tcp":{"port":"{port.main}"}}"#.utf8)),
                       .tcp(port: "{port.main}"))
        XCTAssertEqual(try decoder.decode(Readiness.self, from: Data(#"{"unixSocket":{"path":"{socket}"}}"#.utf8)),
                       .unixSocket(path: "{socket}"))
        XCTAssertEqual(try decoder.decode(Readiness.self, from: Data(#"{"http":{"url":"http://127.0.0.1:1/","expectStatus":200}}"#.utf8)),
                       .http(url: "http://127.0.0.1:1/", expectStatus: 200))
        let command = try decoder.decode(Readiness.self, from: Data(#"{"command":{"executable":"{bin}/r","arguments":["-q"]}}"#.utf8))
        XCTAssertEqual(command, .command(RecipeCommand(executable: "{bin}/r", arguments: ["-q"])))
        for readiness in [Readiness.tcp(port: "1"), .unixSocket(path: "p"), .http(url: "u", expectStatus: 204), command] {
            XCTAssertEqual(try decoder.decode(Readiness.self, from: JSONEncoder().encode(readiness)), readiness)
        }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Readiness.tcp(port: "1")), as: UTF8.self), #"{"tcp":{"port":"1"}}"#)
    }

    /// The catalog a daemon uses: a development home may name its own file (tests); a real home never.
    func testDaemonCatalogOverrideOnlyInDevelopmentHomes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [recipe("fake", "1.0")])).write(to: file)

        let development = ServiceCatalog.forDaemon(environment: ["PADDOCK_HOME": "/tmp/x",
                                                                 "PADDOCK_SERVICES_CATALOG": file.path])
        XCTAssertEqual(development.recipes.map(\.kind), ["fake"])
        let real = ServiceCatalog.forDaemon(environment: ["PADDOCK_SERVICES_CATALOG": file.path])
        XCTAssertNil(real.recipe(kind: "fake", version: nil))
        XCTAssertNotNil(real.recipe(kind: "mail", version: nil))
    }
}
