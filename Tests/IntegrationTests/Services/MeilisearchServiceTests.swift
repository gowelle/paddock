import Darwin
import XCTest
@testable import PaddockCore

/// The real Meilisearch recipe (from the bundled catalog; the 350 MB binary is cached in Vendor/services/) in a
/// scratch home on a free high port: an instance made before the recipe had a master key gains a random one
/// at its next start and keeps its index; without the key the API refuses everything but /health (also from
/// another web origin); Paddock's PHP, with the key from the .env lines, creates an index, adds a document and
/// finds it; the key and index survive a stop and start and a remove and re-add; Meilisearch listens on
/// 127.0.0.1 only, writes only in its data folder and logs without colour codes. One instance, to keep the
/// suite quick.
final class MeilisearchServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []

    override func setUpWithError() throws {
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        home?.cleanUp()
    }

    private var php: URL { TestSupport.repoVendor.appendingPathComponent("php/8.5/default/php") }

    private func makeManager(_ recipe: ServiceRecipe) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: [recipe]),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    /// The recipe as it was before it had a master key (Paddock's earlier catalog), to show such an instance
    /// gains one.
    private func keyless(_ recipe: ServiceRecipe) -> ServiceRecipe {
        ServiceRecipe(kind: recipe.kind, displayName: recipe.displayName, version: recipe.version, series: recipe.series,
                      seriesInID: recipe.seriesInID, licence: recipe.licence, minimumMacOS: recipe.minimumMacOS,
                      assets: recipe.assets, start: RecipeCommand(executable: recipe.start.executable,
                                                                  arguments: recipe.start.arguments),
                      ready: recipe.ready, stopGraceSeconds: recipe.stopGraceSeconds, ports: recipe.ports,
                      env: ["MEILISEARCH_HOST=http://127.0.0.1:{port.main}", "MEILISEARCH_KEY="], openURL: recipe.openURL,
                      configFiles: recipe.configFiles, readyTimeoutSeconds: recipe.readyTimeoutSeconds, notes: recipe.notes)
    }

    func testMeilisearchIsKeyedIndexesFromPHPAndKeepsItsData() async throws {
        guard FileManager.default.isExecutableFile(atPath: php.path) else {
            throw XCTSkip("Vendored PHP missing; run Scripts/fetch-vendor.sh")
        }
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "meilisearch", version: nil),
                                    "the catalog has Meilisearch")
        let recipe = try await ServiceDownloadCache.localRecipe(bundled)
        let id = "meilisearch-1-57"

        // An instance made without a key (as Paddock's first Meilisearch recipe made them), with a document.
        let before = makeManager(keyless(recipe))
        let added = try await before.add(kind: "meilisearch", version: nil)
        XCTAssertEqual(added.id, id)
        XCTAssertEqual(added.name, "Meilisearch 1.57")
        XCTAssertEqual(added.version, "1.57.0")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertNotEqual(port, 7700, "never the conventional 7700")
        XCTAssertGreaterThanOrEqual(port, home.portBase + 7700)
        XCTAssertEqual(try meili(port, "index", "Paddock on an Intel Mac"), "ok")
        before.stopAll()

        // The recipe with its master key: the next start makes one, and the database accepts it.
        let manager = makeManager(recipe)
        try manager.start(id)
        let key = try XCTUnwrap(try ServiceSecrets.load(from: home.paths.serviceConfig(id))["master_key"])
        XCTAssertEqual(key.count, 43, "32 random bytes")
        let status = try XCTUnwrap(manager.statuses().first)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.mainPort, port)
        XCTAssertEqual(status.env, ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:\(port)"],
                       "the key's line is never in the status")
        XCTAssertEqual(try manager.env(id), ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:\(port)",
                                             "MEILISEARCH_KEY=\(key)"])
        XCTAssertEqual(status.secretEnvNames, ["MEILISEARCH_KEY"])
        XCTAssertFalse(Messages.serviceTable(manager.statuses()).contains(key), "not in paddock service list")
        XCTAssertEqual(status.openURL, "http://127.0.0.1:\(port)")
        XCTAssertEqual(status.notes, ["Search indexes are tied to Meilisearch 1.57; export a dump before changing version."])

        let pid = try XCTUnwrap(manager.processes["service-\(id)"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid), ["127.0.0.1:\(port)"])

        // Without the key: only /health (readiness) answers; reading, exporting, webhooks, experimental
        // features and a cross-origin search are all refused.
        XCTAssertEqual(try meili(port, "unauthenticated"),
                       "health 200, indexes 401, export 401, webhooks 401, features 401, cross-origin search 401")
        // With it, from the .env line: the document made before the key, and a new one.
        XCTAssertEqual(try meili(port, "search", "intel", key: key), "Paddock on an Intel Mac")
        XCTAssertEqual(try meili(port, "add", "Valkey and Meilisearch", key: key), "ok")
        XCTAssertEqual(try meili(port, "search", "valkey", key: key), "Valkey and Meilisearch")

        // Stop and start keep the index and the key.
        manager.stop(id)
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertEqual(kill(pid, 0), -1, "stopped")
        try manager.start(id)
        XCTAssertEqual(try ServiceSecrets.load(from: home.paths.serviceConfig(id))["master_key"], key)
        XCTAssertEqual(try meili(port, "search", "paddock", key: key), "Paddock on an Intel Mac")

        // Everything it writes is in its data folder; beside it in the instance folder (its HOME and working
        // directory) only Paddock's own files; nothing in its run folder (TMPDIR).
        let data = home.paths.serviceData(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("data.ms/VERSION").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: home.paths.serviceHome(id).path)),
                       ["config", "data", ServiceManager.dataVersionFileName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.paths.serviceRun(id).path)
            .filter { $0 != ServiceManager.pidFileName }, [])

        // Its log: never the key, and since this recipe's first start (the keyless one before had them) no
        // colour codes (NO_COLOR).
        let log = manager.logTail(id)
        XCTAssertFalse(log.contains(key), "the key is never logged")
        let keyed = try XCTUnwrap(log.range(of: "A master key has been set"), log)
        XCTAssertFalse(log[keyed.lowerBound...].contains("\u{1B}["), "no ANSI colour codes")

        // Removing keeps the data and its key; adding again uses both.
        let kept = try manager.remove(id, deleteData: false)
        XCTAssertEqual(kept, data)
        let again = try await manager.add(kind: "meilisearch", version: nil)
        XCTAssertEqual(again.id, id)
        XCTAssertEqual(manager.statuses().first?.notice, "Found existing data for Meilisearch 1.57; using it.")
        XCTAssertEqual(try manager.env(id).last, "MEILISEARCH_KEY=\(key)")
        let portAgain = try XCTUnwrap(again.ports["main"])
        XCTAssertEqual(try meili(portAgain, "search", "mac", key: key), "Paddock on an Intel Mac")
        XCTAssertEqual(try meili(portAgain, "unauthenticated"),
                       "health 200, indexes 401, export 401, webhooks 401, features 401, cross-origin search 401")
        manager.stopAll()
    }

    /// One HTTP API operation from Paddock's PHP 8.5 (curl extension), with `key` as the bearer token when one
    /// is given: `index` creates the books index and adds a document, `add` adds another, each waiting until
    /// its task has succeeded; `search` prints the titles found; `unauthenticated` prints the status of each
    /// request made without a key.
    private func meili(_ port: Int, _ operation: String, _ argument: String = "", key: String = "",
                       file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let script = home.root.appendingPathComponent("meili.php")
        if !FileManager.default.fileExists(atPath: script.path) {
            try Data(#"""
            <?php
            [, $port, $op, $arg, $key] = $argv + [3 => '', 4 => ''];
            $base = "http://127.0.0.1:$port";
            function call(string $method, string $url, $body = null, bool $allowError = false, array $extra = []): array {
                global $key;
                $headers = array_merge(['Content-Type: application/json'], $extra);
                if ($key !== '') { $headers[] = "Authorization: Bearer $key"; }
                $c = curl_init($url);
                curl_setopt_array($c, [CURLOPT_CUSTOMREQUEST => $method, CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_TIMEOUT => 10, CURLOPT_HTTPHEADER => $headers]);
                if ($body !== null) { curl_setopt($c, CURLOPT_POSTFIELDS, json_encode($body)); }
                $out = curl_exec($c);
                $code = curl_getinfo($c, CURLINFO_RESPONSE_CODE);
                if ($out === false || ($code >= 400 && !$allowError)) {
                    fwrite(STDERR, "$method $url: $code " . curl_error($c) . " $out\n");
                    exit(1);
                }
                return [$code, json_decode($out, true)];
            }
            function wait(string $base, array $task): void {
                for ($i = 0; $i < 300; $i++) {
                    [, $t] = call('GET', "$base/tasks/{$task['taskUid']}");
                    if ($t['status'] === 'succeeded') { return; }
                    if ($t['status'] === 'failed' || $t['status'] === 'canceled') {
                        fwrite(STDERR, json_encode($t) . "\n");
                        exit(2);
                    }
                    usleep(100000);
                }
                fwrite(STDERR, "task {$task['taskUid']} did not finish\n");
                exit(3);
            }
            switch ($op) {
                case 'index':
                    wait($base, call('POST', "$base/indexes", ['uid' => 'books', 'primaryKey' => 'id'])[1]);
                    wait($base, call('POST', "$base/indexes/books/documents", [['id' => 1, 'title' => $arg]])[1]);
                    echo "ok\n";
                    break;
                case 'add':
                    wait($base, call('POST', "$base/indexes/books/documents", [['id' => 2, 'title' => $arg]])[1]);
                    echo "ok\n";
                    break;
                case 'search':
                    [, $result] = call('POST', "$base/indexes/books/search", ['q' => $arg]);
                    echo implode(',', array_map(fn($hit) => $hit['title'], $result['hits'])), "\n";
                    break;
                case 'unauthenticated':
                    $key = '';
                    $codes = [
                        'health' => call('GET', "$base/health", null, true)[0],
                        'indexes' => call('GET', "$base/indexes", null, true)[0],
                        'export' => call('POST', "$base/export", ['url' => 'http://127.0.0.1:9'], true)[0],
                        'webhooks' => call('POST', "$base/webhooks", ['url' => 'http://127.0.0.1:9'], true)[0],
                        'features' => call('PATCH', "$base/experimental-features", (object)[], true)[0],
                        'cross-origin search' => call('POST', "$base/indexes/books/search", ['q' => 'mac'], true,
                                                      ['Origin: http://elsewhere.example'])[0],
                    ];
                    echo implode(', ', array_map(fn($k, $v) => "$k $v", array_keys($codes), $codes)), "\n";
                    break;
            }
            """#.utf8).write(to: script)
        }
        let process = Process()
        process.executableURL = php
        process.arguments = ["-n", script.path, "\(port)", operation, argument, key]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(operation): \(problem)", file: file, line: line)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
