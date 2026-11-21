import Darwin
import XCTest
@testable import PaddockCore

/// The real Meilisearch recipe (from the bundled catalog; the 350 MB binary is cached in Vendor/services/) in a
/// scratch home on a free high port: Paddock's PHP creates an index, adds a document and finds it over the
/// HTTP API; the index survives a stop and start and a remove and re-add; Meilisearch listens on 127.0.0.1
/// only and keeps everything it writes in the instance's data folder. One instance, to keep the suite quick.
final class MeilisearchServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var manager: ServiceManager?

    override func setUpWithError() throws {
        home = try ServiceHome()
    }

    override func tearDown() {
        manager?.stopAll()
        manager = nil
        home?.cleanUp()
    }

    private var php: URL { TestSupport.repoVendor.appendingPathComponent("php/8.5/default/php") }

    func testMeilisearchIndexesAndFindsADocumentFromPHPAndKeepsIt() async throws {
        guard FileManager.default.isExecutableFile(atPath: php.path) else {
            throw XCTSkip("Vendored PHP missing; run Scripts/fetch-vendor.sh")
        }
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "meilisearch", version: nil),
                                    "the catalog has Meilisearch")
        let recipe = try await ServiceDownloadCache.localRecipe(bundled)
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: [recipe]),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        self.manager = manager

        let added = try await manager.add(kind: "meilisearch", version: nil)
        XCTAssertEqual(added.id, "meilisearch-1-57")
        XCTAssertEqual(added.name, "Meilisearch 1.57")
        XCTAssertEqual(added.version, "1.57.0")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertNotEqual(port, 7700, "never the conventional 7700")
        XCTAssertGreaterThanOrEqual(port, home.portBase + 7700)
        let status = try XCTUnwrap(manager.statuses().first)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.mainPort, port)
        XCTAssertEqual(status.env, ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:\(port)",
                                    "MEILISEARCH_KEY="])
        XCTAssertEqual(status.openURL, "http://127.0.0.1:\(port)")
        XCTAssertEqual(status.notes, ["Search indexes are tied to Meilisearch 1.57; export a dump before changing version."])

        let pid = try XCTUnwrap(manager.processes["service-meilisearch-1-57"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid), ["127.0.0.1:\(port)"])

        XCTAssertEqual(try meili(port, "index", "Paddock on an Intel Mac"), "ok")
        XCTAssertEqual(try meili(port, "search", "intel"), "Paddock on an Intel Mac")
        // No master key in development, on this Mac only: the API needs none, but keys can't be managed.
        XCTAssertEqual(try meili(port, "keys"), "401 missing_master_key")

        // Stop and start keep the index.
        manager.stop("meilisearch-1-57")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertEqual(kill(pid, 0), -1, "stopped")
        try manager.start("meilisearch-1-57")
        XCTAssertEqual(try meili(port, "search", "paddock"), "Paddock on an Intel Mac")

        // Everything it writes is in its data folder; nothing beside it in the instance folder (its HOME and
        // working directory), nothing in its run folder (TMPDIR).
        let data = home.paths.serviceData("meilisearch-1-57")
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("data.ms/VERSION").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: home.paths.serviceHome("meilisearch-1-57").path)),
                       ["config", "data", ServiceManager.dataVersionFileName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.paths.serviceRun("meilisearch-1-57").path)
            .filter { $0 != ServiceManager.pidFileName }, [])

        // Removing keeps the data; adding again uses it.
        let kept = try manager.remove("meilisearch-1-57", deleteData: false)
        XCTAssertEqual(kept, data)
        let again = try await manager.add(kind: "meilisearch", version: nil)
        XCTAssertEqual(again.id, "meilisearch-1-57")
        XCTAssertEqual(manager.statuses().first?.notice, "Found existing data for Meilisearch 1.57; using it.")
        let portAgain = try XCTUnwrap(again.ports["main"])
        XCTAssertEqual(try meili(portAgain, "search", "mac"), "Paddock on an Intel Mac")
        manager.stopAll()
    }

    /// One HTTP API operation from Paddock's PHP 8.5 (curl extension): `index` creates the books index and
    /// adds a document, waiting until each task has succeeded; `search` prints the titles found; `keys` prints
    /// the status and error code of listing the API keys.
    private func meili(_ port: Int, _ operation: String, _ argument: String = "",
                       file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let script = home.root.appendingPathComponent("meili.php")
        if !FileManager.default.fileExists(atPath: script.path) {
            try Data(#"""
            <?php
            [, $port, $op, $arg] = $argv + [3 => ''];
            $base = "http://127.0.0.1:$port";
            function call(string $method, string $url, $body = null, bool $allowError = false): array {
                $c = curl_init($url);
                curl_setopt_array($c, [CURLOPT_CUSTOMREQUEST => $method, CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_TIMEOUT => 10, CURLOPT_HTTPHEADER => ['Content-Type: application/json']]);
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
                case 'search':
                    [, $result] = call('POST', "$base/indexes/books/search", ['q' => $arg]);
                    echo implode(',', array_map(fn($hit) => $hit['title'], $result['hits'])), "\n";
                    break;
                case 'keys':
                    [$code, $result] = call('GET', "$base/keys", null, true);
                    echo "$code {$result['code']}\n";
                    break;
            }
            """#.utf8).write(to: script)
        }
        let process = Process()
        process.executableURL = php
        process.arguments = ["-n", script.path, "\(port)", operation, argument]
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
