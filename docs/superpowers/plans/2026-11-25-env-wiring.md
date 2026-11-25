# One-action `.env` wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command or one click writes a service's `.env` lines into a site's `.env`, updating the keys the service owns and leaving every other line exactly as it was.

**Architecture:** A pure merge (`EnvWiring`) and a small file writer (`EnvFile`) in PaddockCore, shared by a new `paddock env <service> [site]` command and a **Write to .env…** sheet in Settings → Services. No IPC request, daemon change or MCP tool: the lines already come from `.serviceEnv`, secrets included, and the merge and write happen in the client that asked for them.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, macOS 13+, Intel; ArgumentParser for the CLI, SwiftUI for the app, XCTest (with `@testable import PaddockCore`) for the tests.

**Spec:** `docs/superpowers/specs/2026-11-25-env-wiring-design.md` — the plan argues from it; read both.

## Global Constraints

- Do not bump `VERSION` or `PaddockBuild.number`. Do not release or publish anything.
- **Never print, store or log a `.env` value.** Every sentence names keys only. `EnvFile.Problem` carries the system's error sentence, never file contents.
- Refuse a **missing**, **symlinked** or **non-UTF-8** `.env`. Never create one.
- Write with `Data.write(to:options:.atomic)`, then restore the file's previous `posixPermissions` (an atomic write creates a new file). Write nothing when the merge changes nothing.
- No new `Request`, no daemon change, no MCP tool, no new app window. The Doctor is not touched.
- **Never run `swift test` or the integration tests bare.** The owner's Herd holds ports 80/443; only the `CLITests` harness may start a daemon, because it supplies `PADDOCK_HTTP_PORT`, `PADDOCK_HTTPS_PORT` and `PADDOCK_DNS_PORT` on high ports. Use `swift test --filter CLITests` and never anything broader for integration.
- No new dependencies. Match the neighbouring files' style: plain doc comments that say why, no comments that restate the code.
- Commit messages are **one plain sentence**, no conventional-commit prefix (e.g. `Add paddock env <service> [site]`). Never skip hooks.

---

## File Structure

- Create `Sources/PaddockCore/Services/EnvWiring.swift` — the pure merge; no file system access.
- Create `Sources/PaddockCore/Services/EnvFile.swift` — refusals, reading and the atomic write; the only file-system code.
- Modify `Sources/PaddockCore/Messages.swift` — the sentences both surfaces print, plus the `EnvWiring.Result` → sentence and `EnvFile.Problem` → sentence mappings. Find where they go under **Services**, after `secretEnvComment`.
- Create `Sources/paddock/EnvCommands.swift` — the `paddock env <service> [site]` command.
- Modify `Sources/paddock/Paddock.swift:14-16` — register `EnvCommand.self` in the root `subcommands` list.
- Modify `Sources/PaddockCore/App/AppModel+Services.swift` — `writeEnv(_:into:)` beside `copyEnv`.
- Modify `Sources/PaddockApp/Settings/ServicesTab.swift` — the row button and the sheet, mirroring the `createDatabase` sheet.
- Create `Tests/PaddockCoreTests/EnvWiringTests.swift`.
- Create `Tests/PaddockCoreTests/EnvFileTests.swift`.
- Modify `Tests/PaddockCoreTests/AppModelTests.swift` — two `writeEnv` tests after the `copyEnv` tests.
- Modify `Tests/IntegrationTests/CLITests.swift` — refusal cases in the no-daemon and daemon sections.
- Regenerate `docs/images/settings-services-light.png`; update its alt text in `README.md:202`.
- Modify `README.md` (feature row, services section, CLI table) and `docs/releases/0.5.0.md`.

---

### Task 1: The merge and its result sentence

**Files:**
- Create: `Sources/PaddockCore/Services/EnvWiring.swift`
- Modify: `Sources/PaddockCore/Messages.swift` (after `secretEnvComment`)
- Test: `Tests/PaddockCoreTests/EnvWiringTests.swift`

**Interfaces:**
- Produces: `EnvWiring.Result { text, settings, added, updated: String/`[String]` }`, `EnvWiring.merge(existing: String, service lines: [String]) -> EnvWiring.Result`, and `Messages.envWiringResult(_:service:host:) -> String`, `Messages.wiredEnv(service:host:added:updated:) -> String`, `Messages.envAlreadyWired(service:host:) -> String`, `Messages.serviceHasNoEnvLines(_:) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PaddockCoreTests/EnvWiringTests.swift`:

```swift
import XCTest
@testable import PaddockCore

final class EnvWiringTests: XCTestCase {
    // MARK: - Merge

    func testAKeyInPlaceIsUpdatedAndTheRestOfTheFileIsUntouched() {
        let result = EnvWiring.merge(existing: "# App settings\nAPP_KEY=base64:abc\nDB_HOST=old\n# tail\n",
                                     service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(result.text, "# App settings\nAPP_KEY=base64:abc\nDB_HOST=127.0.0.1\n# tail\n")
        XCTAssertEqual(result.settings, ["DB_HOST"])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, ["DB_HOST"])
    }

    func testAKeyTheFileLacksIsAppendedAtTheEndInServiceOrder() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop\n",
                                     service: ["REDIS_HOST=127.0.0.1", "REDIS_PORT=6379"])
        XCTAssertEqual(result.text, "APP_NAME=shop\nREDIS_HOST=127.0.0.1\nREDIS_PORT=6379\n")
        XCTAssertEqual(result.settings, ["REDIS_HOST", "REDIS_PORT"])
        XCTAssertEqual(result.added, ["REDIS_HOST", "REDIS_PORT"])
        XCTAssertEqual(result.updated, [])
    }

    func testAFileWithoutAFinalNewlineGetsOneOnlyBeforeTheFirstAppendedLine() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop",
                                     service: ["DB_HOST=127.0.0.1", "DB_PORT=5432"])
        XCTAssertEqual(result.text, "APP_NAME=shop\nDB_HOST=127.0.0.1\nDB_PORT=5432")
        XCTAssertEqual(result.added, ["DB_HOST", "DB_PORT"])
    }

    func testEveryCopyOfADuplicatedKeyIsUpdated() {
        let result = EnvWiring.merge(existing: "DB_HOST=one\nDB_HOST=two\n", service: ["DB_HOST=three"])
        XCTAssertEqual(result.text, "DB_HOST=three\nDB_HOST=three\n")
        XCTAssertEqual(result.updated, ["DB_HOST"])
        XCTAssertEqual(result.added, [])
    }

    func testAnExportLineIsReplacedByThePlainSetting() {
        let result = EnvWiring.merge(existing: "export DB_HOST=old\r\n", service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(result.text, "DB_HOST=127.0.0.1\r\n")
        XCTAssertEqual(result.updated, ["DB_HOST"])
    }

    func testACRLFFileAppendsCRLFLines() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop\r\n",
                                     service: ["DB_HOST=127.0.0.1", "DB_PORT=5432"])
        XCTAssertEqual(result.text, "APP_NAME=shop\r\nDB_HOST=127.0.0.1\r\nDB_PORT=5432\r\n")
    }

    func testAMixedFileAppendsLF() {
        let result = EnvWiring.merge(existing: "A=1\r\nB=2\n", service: ["C=3"])
        XCTAssertEqual(result.text, "A=1\r\nB=2\nC=3\n")
    }

    func testAValueMayHoldAnEqualsSignOrBeEmpty() {
        let result = EnvWiring.merge(existing: "", service: ["S3_URL=http://localhost:8333/?x=1", "S3_KEY="])
        XCTAssertEqual(result.text, "S3_URL=http://localhost:8333/?x=1\nS3_KEY=")
        XCTAssertEqual(result.settings, ["S3_URL", "S3_KEY"])
        XCTAssertEqual(result.added, ["S3_URL", "S3_KEY"])
    }

    func testServiceCommentsBlankLinesAndNonSettingsAreIgnored() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop\n",
                                     service: ["# Redis", "", "REDIS_HOST=127.0.0.1", "not a setting", "BAD-KEY=x"])
        XCTAssertEqual(result.text, "APP_NAME=shop\nREDIS_HOST=127.0.0.1\n")
        XCTAssertEqual(result.settings, ["REDIS_HOST"])
    }

    func testARepeatedServiceKeyKeepsItsFirstPositionAndItsLastValue() {
        let result = EnvWiring.merge(existing: "", service: ["DB_HOST=old", "DB_PORT=5432", "DB_HOST=new"])
        XCTAssertEqual(result.text, "DB_HOST=new\nDB_PORT=5432")
        XCTAssertEqual(result.settings, ["DB_HOST", "DB_PORT"])
        XCTAssertEqual(result.added, ["DB_HOST", "DB_PORT"])
    }

    func testAMalformedFileLineIsLeftWhereItIsAndTheKeyIsAppended() {
        let result = EnvWiring.merge(existing: "  DB_HOST = old\n\n# c\n", service: ["DB_HOST=new"])
        XCTAssertEqual(result.text, "  DB_HOST = old\n\n# c\nDB_HOST=new\n")
        XCTAssertEqual(result.added, ["DB_HOST"])
    }

    func testAnExistingKeyWithAnEmptyValueIsUpdated() {
        let result = EnvWiring.merge(existing: "S3_KEY=\n", service: ["S3_KEY=abc"])
        XCTAssertEqual(result.text, "S3_KEY=abc\n")
        XCTAssertEqual(result.updated, ["S3_KEY"])
    }

    func testChangesAreListedInTheServicesOrderNotTheFiles() {
        let result = EnvWiring.merge(existing: "B=1\nA=1\n", service: ["A=2", "B=2"])
        XCTAssertEqual(result.text, "B=2\nA=2\n")
        XCTAssertEqual(result.updated, ["A", "B"])
    }

    func testAFileThatAlreadyHasEveryValueChangesNothing() {
        let result = EnvWiring.merge(existing: "DB_HOST=127.0.0.1\n", service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(result.text, "DB_HOST=127.0.0.1\n")
        XCTAssertEqual(result.settings, ["DB_HOST"])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, [])
    }

    func testAServiceWithNoSettingsChangesNothing() {
        let result = EnvWiring.merge(existing: "# only comments\n", service: ["# nothing", ""])
        XCTAssertEqual(result.text, "# only comments\n")
        XCTAssertEqual(result.settings, [])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, [])
    }

    // MARK: - Sentences

    func testTheResultSentenceNamesAddedAndUpdatedKeysOnly() {
        let result = EnvWiring.merge(existing: "DB_HOST=old\n",
                                     service: ["DB_HOST=new", "REDIS_HOST=127.0.0.1"])
        XCTAssertEqual(Messages.envWiringResult(result, service: "Mail", host: "shop.test"),
                       "Wired Mail into shop.test's .env: added REDIS_HOST; updated DB_HOST.")
    }

    func testOnlyAddedOrOnlyUpdatedListsItsOnePart() {
        let added = EnvWiring.merge(existing: "", service: ["REDIS_HOST=127.0.0.1"])
        XCTAssertEqual(Messages.envWiringResult(added, service: "Mail", host: "shop.test"),
                       "Wired Mail into shop.test's .env: added REDIS_HOST.")
        let updated = EnvWiring.merge(existing: "DB_HOST=old\n", service: ["DB_HOST=new"])
        XCTAssertEqual(Messages.envWiringResult(updated, service: "Mail", host: "shop.test"),
                       "Wired Mail into shop.test's .env: updated DB_HOST.")
    }

    func testNothingToDoSaysTheFileIsAlreadyWired() {
        let result = EnvWiring.merge(existing: "DB_HOST=127.0.0.1\n", service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(Messages.envWiringResult(result, service: "Mail", host: "shop.test"),
                       "shop.test's .env already has every line from Mail.")
    }

    func testAServiceWithNoSettingsSaysSo() {
        let result = EnvWiring.merge(existing: "A=1\n", service: ["# nothing"])
        XCTAssertEqual(Messages.envWiringResult(result, service: "Mail", host: "shop.test"),
                       "Mail has no .env lines to wire.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter EnvWiringTests`
Expected: the target fails to compile — `cannot find 'EnvWiring' in scope`.

- [ ] **Step 3: Write the merge**

Create `Sources/PaddockCore/Services/EnvWiring.swift`:

```swift
import Foundation

/// Merges a service's `.env` lines into a site's `.env` text. The keys the service defines are updated where
/// they already appear and appended where they don't; every other byte is left as it was.
public enum EnvWiring {
    public struct Result: Equatable, Sendable {
        /// The whole new file.
        public let text: String
        /// Every key the service defines, each once, in the service's order.
        public let settings: [String]
        /// Keys the file lacked, in the service's order.
        public let added: [String]
        /// Keys whose line changed, in the service's order.
        public let updated: [String]
    }

    public static func merge(existing: String, service lines: [String]) -> Result {
        let service = parsed(lines)
        guard !service.keys.isEmpty else {
            return Result(text: existing, settings: [], added: [], updated: [])
        }
        let newline = appendedNewline(of: existing)
        var lines = splitLines(existing)
        let endsWithNewline = lines.last.map { !$0.terminator.isEmpty } ?? false

        var present: Set<String> = []
        var changed: Set<String> = []
        for index in lines.indices {
            let original = lines[index].line
            var line = original
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let found = setting(line), let value = service.values[found.key] else { continue }
            present.insert(found.key)
            let replacement = "\(found.key)=\(value)"
            if replacement != original {
                lines[index].line = replacement
                changed.insert(found.key)
            }
        }

        var text = lines.map { $0.line + $0.terminator }.joined()
        let added = service.keys.filter { !present.contains($0) }
        if !added.isEmpty {
            let block = added.map { "\($0)=\(service.values[$0] ?? "")" }.joined(separator: newline)
            if text.isEmpty {
                text = block
            } else if endsWithNewline {
                text += block + newline
            } else {
                text += newline + block
            }
        }
        return Result(text: text, settings: service.keys, added: added,
                      updated: service.keys.filter { changed.contains($0) })
    }

    /// The text's lines, each with the terminator it had (`\n`, `\r\n`, or none on an unterminated last
    /// line). Scanned by Unicode scalar: `String.split(separator: "\n")` never matches, because `"\r\n"` is
    /// one grapheme cluster in a String.
    private static func splitLines(_ text: String) -> [(line: String, terminator: String)] {
        let scalars = Array(text.unicodeScalars)
        var lines: [(line: String, terminator: String)] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\n" {
                lines.append((String(current), "\n"))
                current = String.UnicodeScalarView()
            } else if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
                lines.append((String(current), "\r\n"))
                current = String.UnicodeScalarView()
                index += 1
            } else {
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty { lines.append((String(current), "")) }
        return lines
    }

    /// The service's settings: comments, blanks and non-settings ignored; a repeated key keeps its first
    /// position and its last value.
    private static func parsed(_ lines: [String]) -> (keys: [String], values: [String: String]) {
        var keys: [String] = []
        var values: [String: String] = [:]
        for line in lines {
            guard let found = setting(line) else { continue }
            if values[found.key] == nil { keys.append(found.key) }
            values[found.key] = found.value
        }
        return (keys, values)
    }

    /// `KEY=value`, with `KEY` matching `[A-Za-z_][A-Za-z0-9_]*` and the value everything after the first `=`.
    private static func setting(_ line: String) -> (key: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<equals])
        guard isKey(key) else { return nil }
        return (key, String(line[line.index(after: equals)...]))
    }

    private static func isKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return key.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// `\r\n` when every line the file terminates ends with `\r\n`; `\n` otherwise.
    private static func appendedNewline(of text: String) -> String {
        let terminated = splitLines(text).filter { !$0.terminator.isEmpty }
        return !terminated.isEmpty && terminated.allSatisfy { $0.terminator == "\r\n" } ? "\r\n" : "\n"
    }
}
```

- [ ] **Step 4: Run the merge tests to verify they pass**

Run: `swift test --filter EnvWiringTests`
Expected: PASS for the merge tests and FAIL for the four sentence tests (`cannot find` is gone; `Messages.envWiringResult` is missing).

- [ ] **Step 5: Add the sentences**

In `Sources/PaddockCore/Messages.swift`, after `secretEnvComment` and before `serviceRemoved`, add:

```swift
    // MARK: - .env wiring

    /// What a finished merge says: the keys that changed, by name — never a value — or that there was nothing
    /// to do.
    public static func envWiringResult(_ result: EnvWiring.Result, service: String, host: String) -> String {
        if result.settings.isEmpty { return serviceHasNoEnvLines(service) }
        if result.added.isEmpty && result.updated.isEmpty { return envAlreadyWired(service: service, host: host) }
        return wiredEnv(service: service, host: host, added: result.added, updated: result.updated)
    }

    /// `Wired mail into shop.test's .env: added REDIS_HOST, REDIS_PORT; updated DB_PASSWORD.`
    public static func wiredEnv(service: String, host: String, added: [String], updated: [String]) -> String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("added " + added.joined(separator: ", ")) }
        if !updated.isEmpty { parts.append("updated " + updated.joined(separator: ", ")) }
        return "Wired \(service) into \(host)'s .env: \(parts.joined(separator: "; "))."
    }

    public static func envAlreadyWired(service: String, host: String) -> String {
        "\(host)'s .env already has every line from \(service)."
    }

    public static func serviceHasNoEnvLines(_ service: String) -> String {
        "\(service) has no .env lines to wire."
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter EnvWiringTests`
Expected: PASS (all 19 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PaddockCore/Services/EnvWiring.swift Sources/PaddockCore/Messages.swift Tests/PaddockCoreTests/EnvWiringTests.swift
git commit -m "Merge a service's .env lines into a site's .env text"
```

---

### Task 2: The file writer and its refusals

**Files:**
- Create: `Sources/PaddockCore/Services/EnvFile.swift`
- Modify: `Sources/PaddockCore/Messages.swift` (after `serviceHasNoEnvLines` from Task 1)
- Test: `Tests/PaddockCoreTests/EnvFileTests.swift`

**Interfaces:**
- Consumes: `EnvWiring.merge(existing:service:)` and its `Result` (Task 1).
- Produces: `EnvFile.Problem` (`.missing`, `.symlink`, `.notUTF8`, `.unreadable(String)`, `.unwritable(String)`), `EnvFile.wire(_ lines: [String], intoSiteAt sitePath: String) throws -> EnvWiring.Result`, and `Messages.envWiringProblem(_:host:) -> String`, `Messages.noEnvFile(_:)`, `Messages.symlinkedEnvFile(_:)`, `Messages.utf8EnvFile(_:)`, `Messages.couldntReadEnvFile(_:reason:)`, `Messages.couldntWriteEnvFile(_:reason:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PaddockCoreTests/EnvFileTests.swift`:

```swift
import Darwin
import XCTest
@testable import PaddockCore

final class EnvFileTests: XCTestCase {
    private func siteFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(".env")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func contents(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8)
    }

    private func env(_ folder: URL) -> URL { folder.appendingPathComponent(".env") }

    func testItWritesTheMergedFileAndKeepsTheFilesPermissions() throws {
        let folder = try siteFolder()
        let file = try write("DB_HOST=old\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let result = try EnvFile.wire(["DB_HOST=127.0.0.1", "DB_PORT=5432"], intoSiteAt: folder.path)
        XCTAssertEqual(try contents(folder), "DB_HOST=127.0.0.1\nDB_PORT=5432\n")
        XCTAssertEqual(result.added, ["DB_PORT"])
        XCTAssertEqual(result.updated, ["DB_HOST"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAMissingEnvFileIsRefusedAndNothingIsCreated() throws {
        let folder = try siteFolder()
        XCTAssertThrowsError(try EnvFile.wire(["A=1"], intoSiteAt: folder.path)) {
            XCTAssertEqual($0 as? EnvFile.Problem, .missing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: env(folder).path))
    }

    func testASymlinkedEnvFileIsRefusedAndItsTargetIsUntouched() throws {
        let folder = try siteFolder()
        let target = folder.appendingPathComponent("real.env")
        try Data("DB_HOST=old\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: env(folder).path, withDestinationPath: "real.env")
        XCTAssertThrowsError(try EnvFile.wire(["DB_HOST=new"], intoSiteAt: folder.path)) {
            XCTAssertEqual($0 as? EnvFile.Problem, .symlink)
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "DB_HOST=old\n")
    }

    func testANonUTF8EnvFileIsRefusedAndLeftAlone() throws {
        let folder = try siteFolder()
        let bytes = Data([0x41, 0x3D, 0xFF, 0x0A])
        try bytes.write(to: env(folder))
        XCTAssertThrowsError(try EnvFile.wire(["B=2"], intoSiteAt: folder.path)) {
            XCTAssertEqual($0 as? EnvFile.Problem, .notUTF8)
        }
        XCTAssertEqual(try Data(contentsOf: env(folder)), bytes)
    }

    func testNothingToDoWritesNothing() throws {
        let folder = try siteFolder()
        let file = try write("A=1\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let result = try EnvFile.wire(["A=1"], intoSiteAt: folder.path)
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, [])
        XCTAssertEqual(try contents(folder), "A=1\n")
    }

    func testAnUnreadableEnvFileReportsTheSystemsSentence() throws {
        try XCTSkipIf(getuid() == 0, "root reads anything")
        let folder = try siteFolder()
        let file = try write("A=1\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try EnvFile.wire(["A=2"], intoSiteAt: folder.path)) {
            guard case .unreadable(let reason)? = $0 as? EnvFile.Problem else {
                return XCTFail("expected unreadable, got \($0)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testAWriteIntoAReadOnlyFolderReportsUnwritable() throws {
        try XCTSkipIf(getuid() == 0, "root writes anywhere")
        let folder = try siteFolder()
        try write("A=1\n", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try EnvFile.wire(["A=2"], intoSiteAt: folder.path)) {
            guard case .unwritable(let reason)? = $0 as? EnvFile.Problem else {
                return XCTFail("expected unwritable, got \($0)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testEachProblemBecomesItsSentence() {
        XCTAssertEqual(Messages.envWiringProblem(.missing, host: "shop.test"),
                       "shop.test has no .env. Create one from .env.example first; "
                       + "Paddock won't write secrets into a new file.")
        XCTAssertEqual(Messages.envWiringProblem(.symlink, host: "shop.test"),
                       "shop.test's .env is a symlink; Paddock won't write through it.")
        XCTAssertEqual(Messages.envWiringProblem(.notUTF8, host: "shop.test"),
                       "shop.test's .env isn't UTF-8; Paddock left it alone.")
        XCTAssertEqual(Messages.envWiringProblem(.unreadable("No permission."), host: "shop.test"),
                       "Paddock couldn't read shop.test's .env: No permission.")
        XCTAssertEqual(Messages.envWiringProblem(.unreadable("No permission"), host: "shop.test"),
                       "Paddock couldn't read shop.test's .env: No permission.")
        XCTAssertEqual(Messages.envWiringProblem(.unwritable("Disk full"), host: "shop.test"),
                       "Paddock couldn't write shop.test's .env: Disk full.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter EnvFileTests`
Expected: the target fails to compile — `cannot find 'EnvFile' in scope`.

- [ ] **Step 3: Write the file writer**

Create `Sources/PaddockCore/Services/EnvFile.swift`:

```swift
import Foundation

/// Writes a service's lines into a site's `.env`, refusing what it can't do safely. Nothing is created and
/// nothing is written when it refuses.
public enum EnvFile {
    public enum Problem: Error, Equatable {
        case missing
        case symlink
        case notUTF8
        case unreadable(String)
        case unwritable(String)
    }

    public static func wire(_ lines: [String], intoSiteAt sitePath: String) throws -> EnvWiring.Result {
        let url = URL(fileURLWithPath: sitePath, isDirectory: true).appendingPathComponent(".env")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw Problem.symlink
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Problem.missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Problem.unreadable(error.localizedDescription)
        }
        guard let existing = String(data: data, encoding: .utf8) else { throw Problem.notUTF8 }
        let result = EnvWiring.merge(existing: existing, service: lines)
        guard result.text != existing else { return result }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try Data(result.text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Problem.unwritable(error.localizedDescription)
        }
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return result
    }
}
```

- [ ] **Step 4: Add the refusal sentences**

In `Sources/PaddockCore/Messages.swift`, directly after `serviceHasNoEnvLines` from Task 1, add:

```swift
    public static func noEnvFile(_ host: String) -> String {
        "\(host) has no .env. Create one from .env.example first; Paddock won't write secrets into a new file."
    }

    public static func symlinkedEnvFile(_ host: String) -> String {
        "\(host)'s .env is a symlink; Paddock won't write through it."
    }

    public static func utf8EnvFile(_ host: String) -> String {
        "\(host)'s .env isn't UTF-8; Paddock left it alone."
    }

    public static func couldntReadEnvFile(_ host: String, reason: String) -> String {
        "Paddock couldn't read \(host)'s .env: \(ending(reason))"
    }

    public static func couldntWriteEnvFile(_ host: String, reason: String) -> String {
        "Paddock couldn't write \(host)'s .env: \(ending(reason))"
    }

    /// The sentence for a refused or failed write, as the CLI prints it and the app shows it.
    public static func envWiringProblem(_ problem: EnvFile.Problem, host: String) -> String {
        switch problem {
        case .missing: return noEnvFile(host)
        case .symlink: return symlinkedEnvFile(host)
        case .notUTF8: return utf8EnvFile(host)
        case .unreadable(let reason): return couldntReadEnvFile(host, reason: reason)
        case .unwritable(let reason): return couldntWriteEnvFile(host, reason: reason)
        }
    }

    /// The system's sentence usually ends with its own period; never print two.
    private static func ending(_ sentence: String) -> String {
        sentence.hasSuffix(".") ? sentence : sentence + "."
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter EnvFileTests`
Expected: PASS (8 tests; the two permission tests skip only when run as root).

- [ ] **Step 6: Commit**

```bash
git add Sources/PaddockCore/Services/EnvFile.swift Sources/PaddockCore/Messages.swift Tests/PaddockCoreTests/EnvFileTests.swift
git commit -m "Write a merged .env back atomically, refusing what it can't do safely"
```

---

### Task 3: `paddock env <service> [site]`

**Files:**
- Create: `Sources/paddock/EnvCommands.swift`
- Modify: `Sources/paddock/Paddock.swift` (the root `subcommands` list)
- Test: `Tests/IntegrationTests/CLITests.swift`

**Interfaces:**
- Consumes: `EnvFile.wire`, `Messages.envWiringResult`, `Messages.envWiringProblem`, `CLI.refuseChangesFromDevelopmentBuild()`, `CLI.service(named:in:)`, `CLI.site(named:in:)`, `CLI.send`, `CLI.sendRaw`.
- Produces: the `EnvCommand` type, registered as `paddock env`.

- [ ] **Step 1: Write the failing tests**

In `Tests/IntegrationTests/CLITests.swift`, add to the **No daemon** section (after `testDoctorWithoutDaemonNamesStart`):

```swift
    func testEnvWithoutDaemonSaysNotRunning() throws {
        let result = try run(["env", "mail"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains(Messages.daemonNotRunning), result.err)
    }
```

And to the **With a daemon** section (after `testUnknownSiteIsAnErrorOnStderr`):

```swift
    func testEnvOutsideASiteNamesTheSiteProblemFirst() throws {
        try launchDaemon()
        let result = try run(["env", "mail"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains(Messages.notASite), result.err)
    }

    func testEnvWithAnUnknownServiceNamesIt() throws {
        try launchDaemon()
        let result = try run(["env", "mail", "plain-php"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains("No service named \"mail\"."), result.err)
    }
```

And, still in the **No daemon** section, after the first test:

```swift
    func testEnvRequiresItsServiceArgument() throws {
        let result = try run(["env"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("service"), result.err)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CLITests`
Expected: FAIL — `paddock env` is an unknown subcommand, so the exit status and stderr do not match.

- [ ] **Step 3: Write the command**

Create `Sources/paddock/EnvCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PaddockCore

/// `paddock env <service> [site]`: writes a service's `.env` lines into a site's `.env`, updating its keys in
/// place. The lines hold secrets, so it refuses a development build on the real system, and it never prints a
/// value.
struct EnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Write a service's .env lines into a site's .env, updating its keys in place.")
    @Argument(help: "The service's name or id, such as mail.") var service: String
    @Argument(help: "The site's name or host (default: the site containing this folder).") var site: String?

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let status = try CLI.send(.status, timeout: 30)
        // The site first, as the spec orders: a wrong site and a wrong service in one command report the site.
        let site = try CLI.site(named: site, in: status)
        let service = try CLI.service(named: service, in: status)
        let lines: [String]
        switch try CLI.sendRaw(.serviceEnv(id: service.id), timeout: 30) {
        case .envLines(let found): lines = found
        case .error(_, let message): throw CLI.failure(message)
        case .ok, .catalog, .removed, .databaseCreated: throw CLI.unexpectedAnswer()
        }
        let result: EnvWiring.Result
        do {
            result = try EnvFile.wire(lines, intoSiteAt: site.path)
        } catch let problem as EnvFile.Problem {
            throw CLI.failure(Messages.envWiringProblem(problem, host: site.host))
        }
        print(Messages.envWiringResult(result, service: service.name, host: site.host))
    }
}
```

In `Sources/paddock/Paddock.swift`, add `EnvCommand.self` to the subcommands list (after `Logs.self`):

```swift
            Open.self, Logs.self, EnvCommand.self,
```

- [ ] **Step 4: Run the CLI tests to verify they pass**

Run: `swift build && swift test --filter CLITests`
Expected: `swift build` succeeds; the whole `CLITests` class passes, including the four new tests. If the harness reports a missing `paddock` binary, `swift build` did not finish before the tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/paddock/EnvCommands.swift Sources/paddock/Paddock.swift Tests/IntegrationTests/CLITests.swift
git commit -m "Add paddock env <service> [site]"
```

---

### Task 4: **Write to .env…** in Settings → Services

**Files:**
- Modify: `Sources/PaddockCore/App/AppModel+Services.swift` (after `copyEnv`)
- Modify: `Sources/PaddockApp/Settings/ServicesTab.swift`
- Test: `Tests/PaddockCoreTests/AppModelTests.swift` (after `testCopyEnvFromADevelopmentBuildIsRefusedWithItsSentence`)
- Regenerate: `docs/images/settings-services-light.png`
- Modify: `README.md:202` (the image's alt text)

**Interfaces:**
- Consumes: `EnvFile.wire`, `Messages.envWiringResult`, `Messages.envWiringProblem`, `Messages.couldntWriteEnvFile`, `act(.serviceEnv(id:), timeout:)`, `showNotice`.
- Produces: `AppModel.writeEnv(_ id: String, into site: Site) async`; `ServiceRowView` gains a `writeEnv: () -> Void` parameter beside `createDatabase`.

- [ ] **Step 1: Write the failing model tests**

In `Tests/PaddockCoreTests/AppModelTests.swift`, after `testCopyEnvFromADevelopmentBuildIsRefusedWithItsSentence`, add:

```swift
    /// Write to .env… fetches the full lines and writes them into the chosen site's `.env`, saying what changed
    /// by key name only: nothing goes to the pasteboard and no value is kept or shown.
    func testWriteEnvUpdatesTheSitesFileAndNamesTheKeys() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdk writeenv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try Data("DB_HOST=old\n".utf8).write(to: folder.appendingPathComponent(".env"))
        let full = ["DB_HOST=127.0.0.1", "MEILISEARCH_KEY=\(secretKey)"]
        let (model, client, outside) = servicesModel { request in
            if case .serviceEnv = request { return .envLines(full) }
            return .ok(statusWith(services: [meili]))
        }
        await model.refresh()
        let site = Site(name: "shop", path: folder.path, kind: .parked, secured: false, php: v85, pinned: false)
        await model.writeEnv("meilisearch-1-57", into: site)
        XCTAssertEqual(client.requests.filter { $0 != .status }, [.serviceEnv(id: "meilisearch-1-57")])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8),
                       "DB_HOST=127.0.0.1\nMEILISEARCH_KEY=\(secretKey)\n")
        XCTAssertEqual(model.serviceNotice,
                       "Wired Meilisearch 1.57 into shop.test's .env: added MEILISEARCH_KEY; updated DB_HOST.")
        XCTAssertEqual(outside.copied, [], "nothing goes to the pasteboard")
        XCTAssertFalse((model.serviceNotice ?? "").contains(secretKey))
        XCTAssertNil(model.lastError)
    }

    func testWriteEnvIntoASiteWithoutAnEnvFileSaysWhyItRefused() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdk writeenv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let (model, _, _) = servicesModel { request in
            if case .serviceEnv = request { return .envLines(["A=1"]) }
            return .ok(statusWith(services: [meili]))
        }
        let site = Site(name: "shop", path: folder.path, kind: .parked, secured: false, php: v85, pinned: false)
        await model.writeEnv("meilisearch-1-57", into: site)
        XCTAssertEqual(model.serviceNotice,
                       "shop.test has no .env. Create one from .env.example first; "
                       + "Paddock won't write secrets into a new file.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".env").path))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AppModelTests`
Expected: the target fails to compile — `value of type 'AppModel' has no member 'writeEnv'`.

- [ ] **Step 3: Write `writeEnv`**

In `Sources/PaddockCore/App/AppModel+Services.swift`, after `copyEnv` and before `openService`, add:

```swift
    /// Writes the service's full `.env` lines into `site`'s `.env`, updating its keys in place. The notice names
    /// the keys that changed; no value is shown or kept.
    public func writeEnv(_ id: String, into site: Site) async {
        let name = serviceName(id)
        guard case .envLines(let lines)? = await act(.serviceEnv(id: id), timeout: 30) else { return }
        do {
            let result = try EnvFile.wire(lines, intoSiteAt: site.path)
            showNotice(Messages.envWiringResult(result, service: name, host: site.host))
        } catch let problem as EnvFile.Problem {
            showNotice(Messages.envWiringProblem(problem, host: site.host))
        } catch {
            showNotice(Messages.couldntWriteEnvFile(site.host, reason: error.localizedDescription))
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AppModelTests`
Expected: PASS, including both new tests.

- [ ] **Step 5: Add the button and the sheet**

In `Sources/PaddockApp/Settings/ServicesTab.swift`:

Add two states beside `databaseFor`:

```swift
    /// The service whose **Write to .env…** sheet is open, and the site it will write into.
    @SwiftUI.State private var envFor: String?
    @SwiftUI.State private var envSite: String?
```

Change the row call to pass the new closure:

```swift
                    ForEach(model.serviceRows) { row in
                        ServiceRowView(row: row, createDatabase: {
                            databaseName = ""
                            databaseFor = row.id
                        }, writeEnv: {
                            envSite = model.sites.first?.name
                            envFor = row.id
                        })
                        Divider()
                    }
```

Add the sheet modifier after the existing `.sheet` for `databaseFor`:

```swift
        .sheet(isPresented: Binding(get: { envFor != nil }, set: { if !$0 { envFor = nil } })) {
            writeEnvSheet
        }
```

Add the sheet beside `createDatabaseSheet`:

```swift
    private var writeEnvSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Wire \(model.serviceRows.first { $0.id == envFor }?.name ?? "") into a site's .env")
                .font(.headline)
            if model.sites.isEmpty {
                Caption("No sites yet.")
            } else {
                Picker("Site", selection: $envSite) {
                    ForEach(model.sites) { site in
                        Text(verbatim: site.host).tag(Optional(site.name))
                    }
                }
                .fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { envFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Write") {
                    guard let id = envFor, let name = envSite,
                          let site = model.sites.first(where: { $0.name == name }) else { return }
                    envFor = nil
                    Task { await model.writeEnv(id, into: site) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(envSite == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
```

In `ServiceRowView`, add the property beside `createDatabase`:

```swift
    let writeEnv: () -> Void
```

and the button after **Copy .env**:

```swift
                Button("Write to .env…", action: writeEnv)
                    .disabled(model.sites.isEmpty)
```

- [ ] **Step 6: Build, regenerate the snapshot and check it**

Run:

```bash
swift build
.build/debug/PaddockApp --snapshots /tmp/paddock-snapshots
cp /tmp/paddock-snapshots/settings-services-light.png docs/images/settings-services-light.png
```

Open `docs/images/settings-services-light.png` and confirm the Services rows show **Write to .env…** (disabled in this sample, which has no sites) and no row is clipped at the 540-point window width. Print no other value: the snapshot's sample services have no secrets.

In `README.md`, update the image's alt text on the `settings-services-light.png` line:

```markdown
  <img src="docs/images/settings-services-light.png" width="420" alt="The Services tab: Meilisearch, PostgreSQL and Mail with Start, Stop, Restart, Copy .env, Write to .env and Remove">
```

- [ ] **Step 7: Run the app-model tests and the build again**

Run: `swift test --filter AppModelTests && swift build`
Expected: PASS and a clean build (no new warnings).

- [ ] **Step 8: Commit**

```bash
git add Sources/PaddockCore/App/AppModel+Services.swift Sources/PaddockApp/Settings/ServicesTab.swift \
  Tests/PaddockCoreTests/AppModelTests.swift docs/images/settings-services-light.png README.md
git commit -m "Add Write to .env… to Settings → Services"
```

---

### Task 5: Documentation and the full gate

**Files:**
- Modify: `README.md` (feature table, Services section, CLI table)
- Modify: `docs/releases/0.5.0.md`

**Interfaces:**
- Consumes: everything above. No new code.

- [ ] **Step 1: Add the feature-table row**

In `README.md`, after the **One-action services** row (line 96), add:

```markdown
| **One-action `.env` wiring** | **Write to .env…** (or `paddock env <service> [site]`) updates a site's `.env` with the keys a service owns, in place, and leaves every other line exactly as it was. |
```

- [ ] **Step 2: Say it in the Services section**

In `README.md`, after the "Every service:" bullet list (after the "keeps its data…" bullet), add:

```markdown
A site's `.env` is wired in one action too: **Write to .env…** in Settings → Services, or
`paddock env <name> [site]`, writes the service's keys into that site's `.env` and leaves
every other line as it was. Keys the file already sets are updated in place. A missing,
symlinked or non-UTF-8 `.env` is refused, never created, and no value is ever printed.
```

- [ ] **Step 3: Add the CLI table row**

In `README.md`, at the end of the Services command table (after `paddock service open <name>`), add:

```markdown
| `paddock env <name> [site]` | Write a service's `.env` lines into a site's `.env`, updating its keys in place. |
```

- [ ] **Step 4: Add the release note bullet**

In `docs/releases/0.5.0.md`, append:

```markdown
- `paddock env <service> [site]` and **Write to .env…** in Settings → Services write a service's keys into a site's `.env`, updating them in place and leaving every other line untouched. The file must already exist, must not be a symlink and must be UTF-8; keys are named in the result, values never are.
```

- [ ] **Step 5: Run the full gate**

Run each, in order:

```bash
swift build
swift test --filter PaddockCoreTests
swift test --filter CLITests
swift test --skip IntegrationTests
```

Expected: build clean (0 warnings); `PaddockCoreTests` PASS; `CLITests` PASS; `--skip IntegrationTests` PASS. Never run `swift test` bare. If `DumpListenerTests.testLinesSentOverTCPArriveOneByOneAndStoppingClosesThePort` fails, it is the known pre-existing flake (a port still holding just after stop); re-run it once and report it rather than changing it here.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/releases/0.5.0.md
git commit -m "Document one-action .env wiring"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| `EnvWiring.Result` and `merge` with the parse/match/append rules | 1 |
| `Messages.wiredEnv`, `envAlreadyWired`, `serviceHasNoEnvLines`, `envWiringResult` | 1 |
| `EnvFile.Problem`, `wire` refusals (missing, symlink, non-UTF-8, unreadable), atomic write and permissions, nothing-to-do | 2 |
| `Messages.noEnvFile`, `symlinkedEnvFile`, `utf8EnvFile`, `couldntReadEnvFile`, `couldntWriteEnvFile`, `envWiringProblem` | 2 |
| `paddock env <service> [site]`: order site → service → lines → wire, development-build refusal, exit codes, never a value | 3 |
| `AppModel.writeEnv` and the **Write to .env…** sheet (site picker, default first, no sites → disabled + caption, closes after writing) | 4 |
| Snapshot regeneration and its README alt text | 4 |
| README feature row, services sentence, CLI table; release note; no version bump | 5 |
| Tests: `EnvWiringTests`, `EnvFileTests`, `AppModelTests`, `CLITests`, gates | 1–5 |

**Placeholder scan:** no TBD/TODO; every code step carries the full code and every test carries its assertions. Nothing is described as "similar to Task N".

**Type consistency:** `EnvWiring.Result` has exactly `text`, `settings`, `added`, `updated` everywhere; `EnvFile.wire(_:intoSiteAt:)` and `EnvFile.Problem` are used with the same names in Tasks 2–4; `Messages.envWiringResult`, `envWiringProblem` and the individual sentence functions keep their signatures between the definition, the CLI and the app; `writeEnv(_:into:)` matches its call sites in `ServicesTab` and the model tests.

**Deliberate wording rulings**

- The sentence uses the service's display name (`service.name`, e.g. `Mail`, `Meilisearch 1.57`), as `serviceRemoved` does; the spec's `mail` example is illustrative.
- `EnvFile.wire` checks the symlink before existence, so a dangling `.env` link is reported as a symlink rather than a missing file.
- `Messages.envWiringProblem` is the one place a `Problem` becomes a sentence, so the CLI and the app cannot drift.

**Corrections after the first dispatch:** `EnvWiring.merge` splits lines by Unicode scalar (`splitLines`), not with `String.split(separator: "\n")`: Swift reads `"\r\n"` as one grapheme cluster, so that separator never matches and CRLF files lost both their terminator and the appended newline. The 19 tests were correct and are unchanged.
