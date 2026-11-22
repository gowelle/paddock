import Darwin
import XCTest
@testable import PaddockCore

/// The real object storage recipe (SeaweedFS, from the bundled catalog; its archive cached in Vendor/services/),
/// in scratch homes on free high ports, spoken to with signed S3 requests from the Mac's own curl.
final class StorageServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var started: Set<Int32> = []

    override func setUpWithError() throws {
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        for pid in started where kill(pid, 0) == 0 && isOurs(pid) {
            XCTFail("weed \(pid) was left running")
            kill(pid, SIGKILL)
        }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private static let portNames = ["main", "s3grpc", "master", "mastergrpc", "volume", "volumegrpc", "filer", "filergrpc"]

    private func storage() async throws -> ServiceRecipe {
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "storage", series: "4"),
                                    "the catalog has object storage")
        return try await ServiceDownloadCache.localRecipe(bundled)
    }

    private func makeManager(_ recipes: [ServiceRecipe], home: ServiceHome? = nil) -> ServiceManager {
        let home = home ?? self.home!
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.1),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    private func server(_ manager: ServiceManager) throws -> Int32 {
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName("storage")].flatMap(TestSupport.pid(from:)))
        started.insert(pid)
        return pid
    }

    private func isOurs(_ pid: Int32) -> Bool {
        guard let program = PortCheck.executablePath(pid: pid) else { return false }
        return program.hasPrefix(home.paths.home.path) || program.hasPrefix("/private" + home.paths.home.path)
    }

    private func isSocket(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// One S3 request with the Mac's curl, signed (SigV4) unless `secret` is nil. Returns the status and body.
    private func s3(_ method: String, _ port: Int, _ path: String, body: String? = nil,
                    key: String = "paddock", secret: String? = "paddock-secret") throws -> (status: Int, body: String) {
        var arguments = ["--silent", "--max-time", "30", "--request", method, "--write-out", "\n%{http_code}"]
        if let secret { arguments += ["--aws-sigv4", "aws:amz:us-east-1:s3", "--user", "\(key):\(secret)"] }
        if let body { arguments += ["--data-binary", body, "--header", "Content-Type: text/plain"] }
        arguments.append("http://127.0.0.1:\(port)\(path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var lines = text.components(separatedBy: "\n")
        let status = Int(lines.popLast() ?? "") ?? 0
        return (status, lines.joined(separator: "\n"))
    }

    /// The Mac's curl signs S3 requests from 7.75 on; without that these tests cannot speak to the service.
    private func requireSigningCurl() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--help", "all"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let help = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard help.contains("--aws-sigv4") else { throw XCTSkip("this Mac's curl cannot sign S3 requests") }
    }

    /// SeaweedFS sockets in /tmp that name one of these ports (the releases after the pinned one make them).
    private func socketsInTmp(_ ports: [Int]) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        return names.filter { name in
            name.hasPrefix("seaweedfs-") && ports.contains { name.contains("-\($0).sock") }
        }
    }

    // MARK: - End to end

    /// Object storage from add to re-add: eight ports of its own, all on this Mac only; its sockets in its own
    /// folder and none in /tmp; the default bucket made once; objects written and read with the key and secret
    /// its `.env` lines give, and refused without them; data kept across a stop and start and a remove and add.
    func testObjectStorageEndToEnd() async throws {
        try requireSigningCurl()
        let manager = makeManager([try await storage()])
        let added = try await manager.add(kind: "storage", version: nil)
        XCTAssertEqual(added.id, "storage")
        XCTAssertEqual(added.name, "Object Storage (S3)")
        XCTAssertEqual(added.version, "4.17")
        XCTAssertEqual(Set(added.ports.keys), Set(Self.portNames))
        XCTAssertEqual(Set(added.ports.values).count, 8, "eight different ports")
        let port = try XCTUnwrap(added.ports["main"])
        let filer = try XCTUnwrap(added.ports["filer"])
        for value in added.ports.values {
            XCTAssertGreaterThan(value, home.portBase, "never one of SeaweedFS's own default ports: \(value)")
        }

        let running = try XCTUnwrap(manager.statuses().first)
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.mainPort, port)
        XCTAssertEqual(running.openURL, "http://127.0.0.1:\(filer)/buckets/")
        XCTAssertEqual(running.env, [
            "FILESYSTEM_DISK=s3", "AWS_ACCESS_KEY_ID=paddock", "AWS_SECRET_ACCESS_KEY=paddock-secret",
            "AWS_DEFAULT_REGION=us-east-1", "AWS_BUCKET=paddock", "AWS_ENDPOINT=http://127.0.0.1:\(port)",
            "AWS_USE_PATH_STYLE_ENDPOINT=true",
        ])

        // Every listener is one of its eight ports, on this Mac only; nothing on a default port, nothing extra.
        let pid = try server(manager)
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid).sorted(),
                       added.ports.values.map { "127.0.0.1:\($0)" }.sorted())

        // Its two local sockets are in its own folder; none in /tmp.
        let folder = home.paths.serviceHome("storage")
        XCTAssertTrue(isSocket(folder.appendingPathComponent("filer.sock")))
        XCTAssertTrue(isSocket(folder.appendingPathComponent("s3.sock")))
        XCTAssertEqual(socketsInTmp(Array(added.ports.values)), [])
        XCTAssertFalse(manager.logTail("storage").lowercased().contains("telemetry"), "no usage reporting")

        // The default bucket was made after the first start, once.
        let marker = home.paths.serviceConfig("storage").appendingPathComponent(ServiceManager.afterReadyMarker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let bucketsMade = { manager.logTail("storage").components(separatedBy: "created bucket paddock").count - 1 }
        XCTAssertEqual(bucketsMade(), 1)

        // An app with the .env lines' key and secret writes and reads; anyone else is refused.
        XCTAssertEqual(try s3("PUT", port, "/paddock/notes/hello.txt", body: "kept by Paddock").status, 200)
        let read = try s3("GET", port, "/paddock/notes/hello.txt")
        XCTAssertEqual(read.status, 200)
        XCTAssertEqual(read.body, "kept by Paddock")
        XCTAssertEqual(try s3("GET", port, "/paddock/notes/hello.txt", secret: nil).status, 403, "unsigned")
        XCTAssertEqual(try s3("GET", port, "/paddock/notes/hello.txt", secret: "wrong").status, 403, "wrong secret")
        XCTAssertEqual(try s3("GET", port, "/paddock/notes/hello.txt", key: "someone").status, 403, "unknown key")
        XCTAssertEqual(try s3("PUT", port, "/paddock/x.txt", body: "no", secret: nil).status, 403, "unsigned write")
        // Another bucket is the app's to make.
        XCTAssertEqual(try s3("PUT", port, "/uploads").status, 200)
        XCTAssertEqual(try s3("PUT", port, "/uploads/a.txt", body: "a").status, 200)

        // Stop and start keep the objects, and the bucket step does not run again.
        manager.stop("storage")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertFalse(kill(pid, 0) == 0, "stopped")
        try manager.start("storage")
        XCTAssertEqual(try s3("GET", port, "/paddock/notes/hello.txt").body, "kept by Paddock")
        XCTAssertEqual(try s3("GET", port, "/uploads/a.txt").body, "a")
        XCTAssertEqual(bucketsMade(), 1, "the bucket was not made again")
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: try server(manager)).count, 8)

        // Removing keeps the data; adding again serves it.
        let data = home.paths.serviceData("storage")
        XCTAssertEqual(try manager.remove("storage", deleteData: false), data)
        let again = try await manager.add(kind: "storage", version: nil)
        XCTAssertEqual(manager.statuses().first?.notice, "Found existing data for Object Storage (S3); using it.")
        let portAgain = try XCTUnwrap(again.ports["main"])
        XCTAssertEqual(try s3("GET", portAgain, "/paddock/notes/hello.txt").body, "kept by Paddock")
        XCTAssertEqual(socketsInTmp(Array(again.ports.values)), [])
        _ = try server(manager)
        manager.stopAll()
    }

    /// A long home: SeaweedFS's sockets are named relative to its folder, so their length never matters; it
    /// serves, and still puts nothing in /tmp.
    func testALongHomeServesAndKeepsItsSocketsInItsFolder() async throws {
        try requireSigningCurl()
        let long = try ServiceHome(longFolder: true)
        defer { long.cleanUp() }
        let manager = makeManager([try await storage()], home: long)
        let added = try await manager.add(kind: "storage", version: nil)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(manager.statuses().first?.state, .running)
        XCTAssertGreaterThan(long.paths.serviceHome("storage").appendingPathComponent("filer.sock").path.utf8.count, 103)
        XCTAssertTrue(isSocket(long.paths.serviceHome("storage").appendingPathComponent("filer.sock")))
        XCTAssertEqual(socketsInTmp(Array(added.ports.values)), [])
        XCTAssertEqual(try s3("PUT", port, "/paddock/a.txt", body: "long").status, 200)
        XCTAssertEqual(try s3("GET", port, "/paddock/a.txt").body, "long")
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName("storage")].flatMap(TestSupport.pid(from:)))
        manager.stopAll()
        XCTAssertFalse(kill(pid, 0) == 0, "stopped")
    }
}
