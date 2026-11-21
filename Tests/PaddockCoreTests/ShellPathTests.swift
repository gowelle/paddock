import XCTest
@testable import PaddockCore

final class ShellPathTests: XCTestCase {
    private var dir: URL!
    private var rc: URL { dir.appendingPathComponent(".zshrc") }
    private let line = #"export PATH="$HOME/Library/Application Support/Paddock/bin:$PATH"  # Added by Paddock"#

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pdk-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func text() throws -> String { try String(contentsOf: rc, encoding: .utf8) }

    func testCreatesMissingFileAndIsConfigured() throws {
        XCTAssertFalse(ShellPath.isConfigured(rcFile: rc))
        try ShellPath.configure(rcFile: rc)
        XCTAssertTrue(ShellPath.isConfigured(rcFile: rc))
        XCTAssertEqual(try text(), line + "\n")
    }

    func testTwiceLeavesExactlyOneMarkerLine() throws {
        try ShellPath.configure(rcFile: rc)
        try ShellPath.configure(rcFile: rc)
        XCTAssertEqual(try text().components(separatedBy: "# Added by Paddock").count - 1, 1)
        XCTAssertEqual(try text(), line + "\n")
    }

    func testPreservesExistingContentWithTrailingNewline() throws {
        try Data("alias ll='ls -l'\n".utf8).write(to: rc)
        try ShellPath.configure(rcFile: rc)
        XCTAssertEqual(try text(), "alias ll='ls -l'\n" + line + "\n")
    }

    func testAddsNewlineWhenExistingContentLacksOne() throws {
        try Data("alias ll='ls -l'".utf8).write(to: rc)
        try ShellPath.configure(rcFile: rc)
        XCTAssertEqual(try text(), "alias ll='ls -l'\n" + line + "\n")
    }

    func testFollowsSymlinkedRcFile() throws {
        let real = dir.appendingPathComponent("dotfiles-zshrc")
        try Data("# mine\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: rc, withDestinationURL: real)
        try ShellPath.configure(rcFile: rc)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rc.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "# mine\n" + line + "\n")
    }

    func testLineSurvivesAHomeWithASpace() throws {
        // The line is a double-quoted shell word, so the space in "Application Support" is safe.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "HOME='/tmp/a b'\n\(line)\necho \"$PATH\""]
        let out = Pipe()
        sh.standardOutput = out
        try sh.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        sh.waitUntilExit()
        XCTAssertTrue(output.hasPrefix("/tmp/a b/Library/Application Support/Paddock/bin:"), output)
    }
}
