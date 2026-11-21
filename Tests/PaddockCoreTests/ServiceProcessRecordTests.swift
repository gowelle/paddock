import Darwin
import XCTest
@testable import PaddockCore

/// The pid record that lets a restarted daemon recognise (and only recognise) its own orphaned service, and
/// the stale-socket rule.
final class ServiceProcessRecordTests: XCTestCase {
    private var dir: URL!
    private var children: [Process] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/pdk-rec-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func startSleep() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        children.append(p)
        return p
    }

    func testRecordsALiveProcessAndRoundTrips() throws {
        let sleep = try startSleep()
        let record = try XCTUnwrap(ServiceProcessRecord.live(pid: sleep.processIdentifier))
        XCTAssertEqual(record.pid, sleep.processIdentifier)
        XCTAssertEqual(record.executable, "/bin/sleep")
        XCTAssertGreaterThan(record.startSeconds, 0)
        let file = dir.appendingPathComponent("pid")
        try record.write(to: file)
        XCTAssertEqual(ServiceProcessRecord.read(from: file), record)
    }

    func testOnlyAMatchingLiveProcessUnderAnAllowedFolderIsOurs() throws {
        let sleep = try startSleep()
        let record = try XCTUnwrap(ServiceProcessRecord.live(pid: sleep.processIdentifier))
        XCTAssertTrue(record.isOurLiveProcess(allowedDirectories: ["/bin"]))
        XCTAssertFalse(record.isOurLiveProcess(allowedDirectories: ["/tmp/pdk-home/services/bin/fake"]),
                       "a program outside the recipe's binaries is never ours")
        let reused = ServiceProcessRecord(pid: record.pid, pgid: record.pgid, startSeconds: record.startSeconds - 100,
                                          startMicroseconds: record.startMicroseconds, executable: record.executable)
        XCTAssertFalse(reused.isOurLiveProcess(allowedDirectories: ["/bin"]), "a reused pid starts at another time")
        let renamed = ServiceProcessRecord(pid: record.pid, pgid: record.pgid, startSeconds: record.startSeconds,
                                           startMicroseconds: record.startMicroseconds, executable: "/bin/sleepy")
        XCTAssertFalse(renamed.isOurLiveProcess(allowedDirectories: ["/bin"]))
        let otherGroup = ServiceProcessRecord(pid: record.pid, pgid: record.pgid + 1, startSeconds: record.startSeconds,
                                              startMicroseconds: record.startMicroseconds, executable: record.executable)
        XCTAssertFalse(otherGroup.isOurLiveProcess(allowedDirectories: ["/bin"]))
        sleep.terminate()
        sleep.waitUntilExit()
        XCTAssertFalse(record.isOurLiveProcess(allowedDirectories: ["/bin"]), "gone")
    }

    func testStaleSocketsAreUnlinkedButNothingElse() throws {
        let run = dir.appendingPathComponent("run/svc/fake", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)

        let socketPath = run.appendingPathComponent("fake.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try XCTUnwrap(Wire.socketAddress(socketPath))
        XCTAssertEqual(withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }, 0)
        close(fd)
        ServiceManager.removeStaleSocket(socketPath, inside: run)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))

        let folder = run.appendingPathComponent("folder.sock", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside"))
        ServiceManager.removeStaleSocket(folder.path, inside: run)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside").path))

        let file = run.appendingPathComponent("file.sock")
        try Data("keep".utf8).write(to: file)
        ServiceManager.removeStaleSocket(file.path, inside: run)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A socket outside the instance's run folder is never touched.
        let outside = dir.appendingPathComponent("outside.sock").path
        let fd2 = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr2 = try XCTUnwrap(Wire.socketAddress(outside))
        _ = withUnsafePointer(to: &addr2) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd2, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd2)
        ServiceManager.removeStaleSocket(outside, inside: run)
        ServiceManager.removeStaleSocket(run.path + "/../../outside.sock", inside: run)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }
}
