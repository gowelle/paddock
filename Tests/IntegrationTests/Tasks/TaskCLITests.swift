import Darwin
import XCTest
@testable import PaddockCore

/// `paddock tasks …` and the tasks in `paddock status`, run as the built CLI against a scratch daemon, with
/// scratch site folders, harmless commands and free high ports.
final class TaskCLITests: XCTestCase {
    private var home: TaskHome!
    private var daemon: Process?
    private var environment: [String: String] = [:]
    private var shop: URL!
    private var plain: URL!

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TaskHome()
        shop = try home.makeSite("shop", tasks: nil)
        try Data("<?php\n".utf8).write(to: shop.appendingPathComponent("artisan"))
        plain = try home.makeSite("plain", tasks: nil)
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        let http = TestSupport.freeTCPPort()
        env["PADDOCK_HTTP_PORT"] = "\(http)"
        env["PADDOCK_HTTPS_PORT"] = "\(TestSupport.freeTCPPort(excluding: [http]))"
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53594))"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env[ServicePorts.portBaseVariable] = "\(TestSupport.freeTCPPort())"
        env[ShellEnvironment.overrideVariable] = try home.environmentFile().path
        environment = env
    }

    override func tearDown() {
        let client = PaddockClient(paths: home.paths)
        if client.daemonIsRunning { _ = try? client.send(.shutdown, timeout: 60) }
        if let daemon, !waitFor(60, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        // A daemon that had to be killed leaves its tasks and web stack: only this home's are signalled.
        for pid in home.leftoverProcesses() where home.owns(pid) { kill(pid, SIGKILL) }
        home?.cleanUp()
    }

    private var shopFile: String { SiteTasksFile.realPath(shop.path)! + "/paddock.json" }

    private func pid(in text: String) -> Int32? { TestSupport.pid(from: text) }

    func testTasksCommands() throws {
        try launchDaemon()

        // Nothing yet.
        XCTAssertEqual(try run(["tasks"], in: shop).out, "shop has no paddock.json. Start one with: paddock tasks init\n")
        XCTAssertEqual(try run(["tasks"]).out,
                       "No site has a paddock.json yet. Start one in a Laravel project with: paddock tasks init\n",
                       "outside a site: every site with tasks")
        let notASite = try run(["tasks", "on"])
        XCTAssertEqual(notASite.status, 1)
        XCTAssertEqual(notASite.err, Messages.notASite + "\n")
        let noFile = try run(["tasks", "on"], in: plain)
        XCTAssertEqual(noFile.status, 1)
        XCTAssertEqual(noFile.err, "plain has no paddock.json. Start one with: paddock tasks init\n")

        // A starter for Laravel, an example for anything else; never over a file.
        let initialised = try run(["tasks", "init"], in: shop)
        XCTAssertEqual(initialised.status, 0, initialised.err)
        XCTAssertEqual(initialised.out, "Wrote \(shopFile). Review and approve its tasks with: paddock tasks on\n")
        XCTAssertEqual(try String(contentsOfFile: shopFile, encoding: .utf8), SiteTasksFile.starter(forSiteAt: shop))
        let again = try run(["tasks", "init"], in: shop)
        XCTAssertEqual(again.status, 1)
        XCTAssertEqual(again.err, "\(shopFile) already exists; Paddock never overwrites it.\n")
        let example = try run(["tasks", "init"], in: plain)
        XCTAssertEqual(example.status, 0, example.err)
        let plainFile = SiteTasksFile.realPath(plain.path)! + "/paddock.json"
        XCTAssertEqual(example.out, "plain isn't a Laravel project, so here is an example to start from. Save it as "
                       + "\(plainFile):\n\n" + SiteTasksFile.example + Messages.forwardingIgnoresCase + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainFile))

        // Harmless commands instead of the starter's.
        // A route to a free high port nothing listens on (no request is ever sent through it here).
        let routePort = TestSupport.freeTCPPort()
        let forward = "forward http://shop.test/app → 127.0.0.1:\(routePort)"
        try home.writeTasks("shop", #"{"tasks": {"worker": {"run": "echo working; exec sleep 600"}}, "proxy": {"/app": \#(routePort)}}"#)
        let waiting = "shop: paddock.json has tasks waiting for your approval. Review them with: paddock tasks on --show\n"
        XCTAssertEqual(try run(["tasks"], in: shop).out, waiting)
        XCTAssertTrue(try run(["status"]).out.hasSuffix("\n" + waiting), "paddock status says so too")

        let shown = try run(["tasks", "on", "--show"], in: shop)
        XCTAssertEqual(shown.status, 0, shown.err)
        XCTAssertEqual(shown.out, "\(shopFile) would run:\n  worker: echo working; exec sleep 600\n"
                       + "  \(forward)\nApprove it with: paddock tasks on\n")
        XCTAssertEqual(try run(["tasks"], in: shop).out, waiting, "showing approves nothing")

        let approved = try run(["tasks", "on"], in: shop)
        XCTAssertEqual(approved.status, 0, approved.err)
        let lines = approved.out.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), ["Approving what \(shopFile) runs:", "  worker: echo working; exec sleep 600",
                                                "  \(forward)", "Approved."])
        XCTAssertTrue(lines[4].hasPrefix("  worker: running (pid "), approved.out)
        let worker = try XCTUnwrap(pid(in: lines[4]))

        let list = try run(["tasks"], in: shop)
        let running = "running (pid \(worker))"
        XCTAssertEqual(list.out, "TASK    " + "STATE".padding(toLength: running.count + 2, withPad: " ", startingAt: 0)
                       + "COMMAND\nworker  \(running)  echo working; exec sleep 600\n\(forward)\n")
        XCTAssertEqual(try run(["tasks", "--site", "shop.test"]).out, list.out, "--site from anywhere")
        XCTAssertEqual(try run(["tasks"]).out, "shop/worker: running (pid \(worker))\nshop: \(forward)\n",
                       "outside a site: every site")
        XCTAssertTrue(try run(["status"]).out.hasSuffix("\nshop/worker: running (pid \(worker))\nshop: \(forward)\n"))

        XCTAssertTrue(waitFor(10) { ((try? self.run(["tasks", "logs", "worker"], in: self.shop).out) ?? "").contains("working") })
        let logPath = home.paths.taskLog(site: "shop", task: "worker").path
        let last = try run(["tasks", "logs", "worker", "-n", "1"], in: shop)
        XCTAssertEqual(last.out, "\(logPath)\nworking\n")
        let unknown = try run(["tasks", "logs", "../../state"], in: shop)
        XCTAssertEqual(unknown.status, 1)
        XCTAssertEqual(unknown.err, "shop has no task named \"../../state\". See: paddock tasks\n")

        let stopped = try run(["tasks", "stop", "worker"], in: shop)
        XCTAssertEqual(stopped.out, "worker stopped.\n", stopped.err)
        XCTAssertFalse(kill(worker, 0) == 0)
        XCTAssertTrue(try run(["tasks"], in: shop).out.contains("worker  stopped by you"))
        let started = try run(["tasks", "start", "worker"], in: shop)
        XCTAssertEqual(started.status, 0, started.err)
        XCTAssertTrue(started.out.hasPrefix("worker is running (pid "), started.out)
        let restarted = try run(["tasks", "restart", "worker"], in: shop)
        XCTAssertTrue(restarted.out.hasPrefix("worker is running (pid "), restarted.out)
        let current = try XCTUnwrap(pid(in: restarted.out))
        let nope = try run(["tasks", "start", "nope"], in: shop)
        XCTAssertEqual(nope.status, 1)
        XCTAssertEqual(nope.err, "shop has no task named \"nope\". See: paddock tasks\n")

        // A changed file keeps the approved version (any tasks request reads the file again); paddock tasks says so.
        try home.writeTasks("shop", #"{"tasks": {"worker": {"run": "echo changed; exec sleep 600"}}}"#)
        XCTAssertEqual(try run(["tasks", "restart", "worker"], in: shop).status, 0)
        let changed = try run(["tasks"], in: shop).out
        XCTAssertTrue(changed.contains("echo working; exec sleep 600"), changed)
        XCTAssertTrue(changed.hasSuffix(Messages.tasksChanged(site: "shop") + "\n"), changed)
        XCTAssertFalse(try run(["tasks", "logs", "worker"], in: shop).out.contains("\nchanged\n"), "the new version never ran")

        let off = try run(["tasks", "off"], in: shop)
        XCTAssertEqual(off.out, "Stopped shop's tasks and withdrew their approval.\n", off.err)
        XCTAssertFalse(kill(current, 0) == 0)

        // Everything stops with Paddock.
        _ = try run(["tasks", "on"], in: shop)
        let last2 = try XCTUnwrap(pid(in: try run(["tasks"], in: shop).out))
        guard case .ok = try PaddockClient(paths: home.paths).send(.shutdown, timeout: 60) else { return XCTFail() }
        XCTAssertTrue(waitFor(30) { kill(last2, 0) != 0 }, "nothing is left running")
    }

    /// A stop that takes a while says what it is waiting for, and returns once the task has stopped.
    func testAStopThatTakesAWhileSaysSo() throws {
        try home.writeTasks("shop", #"{"tasks": {"slow": {"run": "trap '' TERM; while :; do sleep 0.1; done", "stopSeconds": 5}}}"#)
        try launchDaemon()
        XCTAssertEqual(try run(["tasks", "on"], in: shop).status, 0)
        Thread.sleep(forTimeInterval: 0.5)
        let stopped = try run(["tasks", "stop", "slow"], in: shop)
        XCTAssertEqual(stopped.status, 0, stopped.err)
        XCTAssertEqual(stopped.out, "Waiting for slow to finish…\nslow stopped.\n")
    }

    /// Commands are printed whole, however long (up to the 2000 characters a command may have).
    func testALongCommandIsShownWhole() throws {
        let command = "echo " + String(repeating: "x", count: 1979) + "; exec sleep 600"
        XCTAssertEqual(command.unicodeScalars.count, 2000)
        try home.writeTasks("shop", #"{"tasks": {"long": {"run": "\#(command)"}}}"#)
        try launchDaemon()
        let shown = try run(["tasks", "on", "--show"], in: shop)
        XCTAssertEqual(shown.status, 0, shown.err)
        XCTAssertTrue(shown.out.contains("  long: \(command)\n"), "not cut short")
    }

    func testFollowingALog() throws {
        try home.writeTasks("shop", #"{"tasks": {"ticker": {"run": "while :; do echo tick; sleep 0.2; done"}}}"#)
        try launchDaemon()
        XCTAssertEqual(try run(["tasks", "on"], in: shop).status, 0)
        let process = Process()
        process.executableURL = products.appendingPathComponent("paddock")
        process.arguments = ["tasks", "logs", "ticker", "-f", "-n", "0"]
        process.environment = environment
        process.currentDirectoryURL = shop
        let out = home.root.appendingPathComponent("follow.out")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        XCTAssertTrue(waitFor(15) {
            ((try? String(contentsOf: out, encoding: .utf8)) ?? "").components(separatedBy: "tick").count > 4
        }, "new lines keep coming")
        XCTAssertTrue(process.isRunning, "following until interrupted")
        kill(process.processIdentifier, SIGINT)
        XCTAssertTrue(waitFor(5) { !process.isRunning })
    }

    // MARK: - Helpers

    private struct Result { let status: Int32; let out: String; let err: String }

    private var products: URL { Bundle(for: TaskCLITests.self).bundleURL.deletingLastPathComponent() }

    private func run(_ args: [String], in folder: URL? = nil, timeout: TimeInterval = 60) throws -> Result {
        let process = Process()
        process.executableURL = products.appendingPathComponent("paddock")
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = folder ?? home.root
        let outFile = home.root.appendingPathComponent("out-\(TestSupport.token())")
        let errFile = home.root.appendingPathComponent("err-\(TestSupport.token())")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        if !waitFor(timeout, { !process.isRunning }) {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("paddock \(args) timed out")
        }
        process.waitUntilExit()
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return Result(status: process.terminationStatus, out: read(outFile), err: read(errFile))
    }

    private func launchDaemon() throws {
        let process = Process()
        process.executableURL = products.appendingPathComponent("paddockd")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        daemon = process
        guard waitFor(40, { PaddockClient(paths: self.home.paths).daemonIsRunning }) else {
            XCTFail("daemon did not come up")
            throw XCTSkip("daemon did not come up")
        }
    }
}
