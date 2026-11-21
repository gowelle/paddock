import Darwin
import XCTest
@testable import PaddockCore

/// PostGIS, built into Paddock's PostgreSQL: after `add postgres`, `CREATE EXTENSION postgis` works with the
/// service's minimal environment (PROJ finds its database beside its library), its functions answer as they
/// should from Paddock's PHP over TCP, a dump restores identically with the instance's own pg_dump and psql,
/// and an install made before the add-on gains it at its next start with its data kept. Scratch homes, free
/// high ports; archives from Vendor/services/ (theseus) and Vendor/builds/ (the add-on).
final class PostGISTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []

    override func setUpWithError() throws {
        home = try ServiceHome()
        guard FileManager.default.isExecutableFile(atPath: php.path) else {
            throw XCTSkip("Vendored PHP missing; run Scripts/fetch-vendor.sh")
        }
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        home?.cleanUp()
    }

    private var php: URL { TestSupport.repoVendor.appendingPathComponent("php/8.5/default/php") }

    private func postgres(_ series: String) async throws -> ServiceRecipe {
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "postgres", series: series))
        XCTAssertEqual(bundled.assets.count, 2, "PostgreSQL and its PostGIS add-on")
        return try await ServiceDownloadCache.localRecipe(bundled)
    }

    private func makeManager(_ recipes: [ServiceRecipe]) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.1),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    /// Runs SQL statements (separated by lines holding only `;;`) through PDO over TCP with Paddock's PHP;
    /// one output line per statement: its rows joined by `,`, columns by `|`.
    private func sql(_ port: Int, _ database: String, _ statements: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let script = home.root.appendingPathComponent("sql.php")
        if !FileManager.default.fileExists(atPath: script.path) {
            try Data(#"""
            <?php
            $pdo = new PDO($argv[1], 'root', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            foreach (explode("\n;;\n", stream_get_contents(STDIN)) as $statement) {
                if (trim($statement) === '') continue;
                $rows = $pdo->query($statement)->fetchAll(PDO::FETCH_NUM);
                echo implode(',', array_map(fn ($row) => implode('|', array_map('strval', $row)), $rows)), "\n";
            }
            """#.utf8).write(to: script)
        }
        let process = Process()
        process.executableURL = php
        process.arguments = ["-n", script.path, "pgsql:host=127.0.0.1;port=\(port);dbname=\(database)"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(statements.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, problem, file: file, line: line)
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// One of the instance's own programs (pg_dump, psql) with the service's minimal environment.
    private func tool(_ bin: URL, _ name: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = bin.appendingPathComponent("bin/\(name)")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.root.path, "LANG": "en_US.UTF-8",
                               "LC_ALL": "en_US.UTF-8"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    /// The notes' functional checks (Vendor/postgis-build-notes/scripts/functional.sql), with their results.
    private static let setUp = """
        CREATE EXTENSION postgis
        ;;
        CREATE EXTENSION hstore
        ;;
        CREATE TABLE place (id serial PRIMARY KEY, name text NOT NULL, tags hstore, loc geography(Point,4326),
                            area geometry(MultiPolygon,4326))
        ;;
        CREATE INDEX place_loc_gix ON place USING gist (loc)
        ;;
        CREATE INDEX place_area_gix ON place USING gist (area)
        ;;
        INSERT INTO place (name, tags, loc, area) VALUES
         ('Paris', 'kind=>city, country=>FR', ST_SetSRID(ST_MakePoint(2.3522, 48.8566),4326)::geography,
          ST_Multi(ST_GeomFromText('POLYGON((2.2 48.8,2.5 48.8,2.5 48.95,2.2 48.95,2.2 48.8))',4326))),
         ('Versailles', 'kind=>town', ST_SetSRID(ST_MakePoint(2.1301, 48.8049),4326)::geography,
          ST_Multi(ST_GeomFromText('POLYGON((2.05 48.77,2.2 48.77,2.2 48.84,2.05 48.84,2.05 48.77))',4326))),
         ('Bowtie', 'kind=>broken', ST_SetSRID(ST_MakePoint(10.0, 50.0),4326)::geography,
          ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_GeomFromText('POLYGON((9 49,11 51,11 49,9 51,9 49))',4326)),3)))
        """

    private static let checks: [(String, String)] = [
        ("SELECT name FROM place WHERE ST_DWithin(loc, ST_SetSRID(ST_MakePoint(2.3522, 48.8566),4326)::geography, 25000) "
         + "ORDER BY name", "Paris,Versailles"),
        ("SELECT name FROM place WHERE ST_Intersects(area, ST_GeomFromText('LINESTRING(2.1 48.8, 2.3 48.9)',4326)) "
         + "ORDER BY name", "Paris,Versailles"),
        ("SELECT ST_IsValid(ST_GeomFromText('POLYGON((9 49,11 51,11 49,9 51,9 49))',4326))::text, ST_IsValid(area)::text, "
         + "GeometryType(area), ST_NumGeometries(area) FROM place WHERE name='Bowtie'", "false|true|MULTIPOLYGON|2"),
        ("SELECT round(ST_X(ST_Transform(ST_SetSRID(ST_MakePoint(2.3522,48.8566),4326),3857))::numeric,1), "
         + "round(ST_Y(ST_Transform(ST_SetSRID(ST_MakePoint(2.3522,48.8566),4326),3857))::numeric,1)", "261845.7|6250564.3"),
        ("SELECT (ST_AsText(ST_Transform(area,3857)) IS NOT NULL)::text FROM place WHERE name='Paris'", "true"),
        ("SELECT ST_AsGeoJSON(loc) FROM place WHERE name='Paris'", #"{"type":"Point","coordinates":[2.3522,48.8566]}"#),
        (#"SELECT ST_AsText(ST_GeomFromGeoJSON('{"type":"Point","coordinates":[2.3522,48.8566]}'))"#, "POINT(2.3522 48.8566)"),
        ("SELECT round((ST_Distance(a.loc,b.loc)/1000)::numeric,2) FROM place a, place b "
         + "WHERE a.name='Paris' AND b.name='Versailles'", "17.29"),
        ("SELECT name || '=' || (tags->'kind') FROM place ORDER BY id", "Paris=city,Versailles=town,Bowtie=broken"),
        ("SELECT indexname FROM pg_indexes WHERE tablename='place' ORDER BY 1", "place_area_gix,place_loc_gix,place_pkey"),
    ]

    private static let rows = "SELECT id, name, tags::text, ST_AsEWKT(loc), ST_AsEWKT(area) FROM place ORDER BY id"

    func testPostGISInPostgreSQL18() async throws {
        let manager = makeManager([try await postgres("18")])
        let added = try await manager.add(kind: "postgres", version: "18")
        let port = try XCTUnwrap(added.ports["main"])
        let bin = home.paths.serviceBin(kind: "postgres", version: "18.7.0")
        XCTAssertEqual(manager.statuses().first?.notes, ["Includes PostGIS 3.6.4 (no raster or topology)."])
        for database in ["gis1", "gis2"] { XCTAssertEqual(try manager.createDatabase("postgres-18", database: database), .done) }

        // The extension, and where PROJ finds its data: beside libproj, inside this scratch install.
        XCTAssertEqual(try sql(port, "gis1", Self.setUp).count, 6)
        let version = try XCTUnwrap(try sql(port, "gis1", "SELECT postgis_full_version()").first)
        XCTAssertTrue(version.contains(#"POSTGIS="3.6.4 "#), version)
        XCTAssertTrue(version.contains(#"GEOS="3.14.1-"#), version)
        XCTAssertTrue(version.contains(#"PROJ="9.9.0 "#), version)
        let realBin = try XCTUnwrap(ServiceManager.realPath(bin.path))
        XCTAssertTrue(version.contains("DATABASE_PATH=\(realBin)/share/proj/proj.db"), version)
        XCTAssertTrue(version.contains("USER_WRITABLE_DIRECTORY=\(home.paths.serviceHome("postgres-18").path)/"),
                      "PROJ's own folder is under the instance's HOME: \(version)")
        XCTAssertFalse(version.contains(FileManager.default.homeDirectoryForCurrentUser.path),
                       "nothing of PostGIS points into the real home: \(version)")
        XCTAssertEqual(try sql(port, "gis1", "SELECT extname || ' ' || extversion FROM pg_extension ORDER BY 1"),
                       ["hstore 1.8,plpgsql 1.0,postgis 3.6.4"])

        // The functional checks.
        let answers = try sql(port, "gis1", Self.checks.map(\.0).joined(separator: "\n;;\n"))
        XCTAssertEqual(answers, Self.checks.map(\.1))
        let plan = try sql(port, "gis1", "SET enable_seqscan = off\n;;\nEXPLAIN (COSTS OFF) SELECT name FROM place WHERE "
                           + "ST_DWithin(loc, ST_SetSRID(ST_MakePoint(2.35,48.85),4326)::geography, 1000)")
        XCTAssertTrue(plan.last?.contains("Index Scan using place_loc_gix") == true, "\(plan)")

        // A dump and restore with the instance's own pg_dump and psql, over TCP.
        let dump = home.root.appendingPathComponent("gis1.sql")
        let dumped = try tool(bin, "pg_dump", ["--host=127.0.0.1", "--port=\(port)", "--username=root", "--dbname=gis1",
                                               "--file=\(dump.path)"])
        XCTAssertEqual(dumped.0, 0, dumped.1)
        let restored = try tool(bin, "psql", ["-X", "-q", "--host=127.0.0.1", "--port=\(port)", "--username=root",
                                              "--dbname=gis2", "-v", "ON_ERROR_STOP=1", "--file=\(dump.path)"])
        XCTAssertEqual(restored.0, 0, restored.1)
        let original = try sql(port, "gis1", Self.rows)
        XCTAssertEqual(original.first?.split(separator: ",").count ?? 0 > 2, true, "\(original)")
        XCTAssertEqual(try sql(port, "gis2", Self.rows), original, "identical rows after the round trip")
        XCTAssertEqual(try sql(port, "gis2", Self.checks[0].0), [Self.checks[0].1])

        // The add-on's libraries link only to each other and to the system; the service is still loopback only
        // and its programs come from its own binaries.
        for library in ["postgis-3", "libgeos_c.1", "libgeos.3.14.1", "libproj.25", "libjson-c.5"] {
            let linked = try TestSupport.linkedLibraries(bin.appendingPathComponent("lib/\(library).dylib"))
            XCTAssertFalse(linked.isEmpty, library)
            for path in linked {
                XCTAssertTrue(path.hasPrefix("@rpath/") || path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/"),
                              "\(library) links \(path)")
            }
        }
        let pid = try XCTUnwrap(manager.processes["service-postgres-18"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid), ["127.0.0.1:\(port)"])
        XCTAssertTrue(ServiceManager.resolves(PortCheck.executablePath(pid: pid) ?? "", inside: bin))
        manager.stopAll()
    }

    /// 17 and 16: the extension loads and reports its version.
    func testPostGISInPostgreSQL17And16() async throws {
        let manager = makeManager([try await postgres("17"), try await postgres("16")])
        for series in ["17", "16"] {
            let added = try await manager.add(kind: "postgres", version: series)
            let port = try XCTUnwrap(added.ports["main"])
            XCTAssertEqual(try manager.createDatabase(added.id, database: "gis"), .done)
            let lines = try sql(port, "gis", "CREATE EXTENSION postgis\n;;\nSELECT postgis_lib_version(), "
                                + "current_setting('server_version_num')::int / 10000")
            XCTAssertEqual(lines.last, "3.6.4|\(series)")
            manager.stop(added.id)
        }
    }

    /// An instance installed before PostgreSQL came with PostGIS gains the add-on at its next start, from the
    /// app's own archive (no download), with its data kept.
    func testAnInstallWithoutPostGISGainsItAtTheNextStart() async throws {
        let recipe = try await postgres("18")
        let without = ServiceRecipe(
            kind: recipe.kind, displayName: recipe.displayName, version: recipe.version, series: recipe.series,
            seriesInID: recipe.seriesInID, licence: recipe.licence, minimumMacOS: recipe.minimumMacOS,
            assets: [recipe.assets[0]], initialise: recipe.initialise, start: recipe.start, ready: recipe.ready,
            stopSignal: recipe.stopSignal, stopGraceSeconds: recipe.stopGraceSeconds, ports: recipe.ports,
            socket: recipe.socket, env: recipe.env, openURL: recipe.openURL, needsPHP: recipe.needsPHP,
            configFiles: recipe.configFiles, readyTimeoutSeconds: recipe.readyTimeoutSeconds,
            initialiseTimeoutSeconds: recipe.initialiseTimeoutSeconds, actions: recipe.actions, lockFiles: recipe.lockFiles)
        let before = makeManager([without])
        let added = try await before.add(kind: "postgres", version: "18")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try before.createDatabase("postgres-18", database: "app"), .done)
        XCTAssertEqual(try sql(port, "app", "CREATE TABLE kept (v text)\n;;\nINSERT INTO kept VALUES ('mine')\n;;\n"
                               + "SELECT count(*) FROM pg_available_extensions WHERE name = 'postgis'"), ["", "", "0"])
        before.stopAll()

        let after = makeManager([recipe])
        try after.start("postgres-18")
        XCTAssertEqual(try sql(port, "app", "SELECT v FROM kept\n;;\nCREATE EXTENSION postgis\n;;\nSELECT postgis_lib_version()"),
                       ["mine", "", "3.6.4"])
        XCTAssertTrue(after.installer.isInstalled(recipe))
        XCTAssertEqual(after.statuses().first?.version, "18.7.0")
        after.stopAll()
    }
}
