import Foundation
import XCTest
@testable import PaddockCore

final class MCPDoctorTests: MCPToolsTestCase {
    private func statusWithFPM() -> EngineStatus {
        var status = status()
        status.processes["php-fpm-8.4"] = "running (pid 3)"
        return status
    }

    private func doctorTools(_ daemon: MCPFakeDaemon, readOnly: Bool = false) -> MCPTools {
        MCPTools(options: .init(readOnly: readOnly), send: { try daemon.send($0) },
                 logSections: { _ in [] }, mail: MCPFakeMail(),
                 doctor: Doctor(resolve: { _ in ["127.0.0.1"] }, readable: { _ in true },
                                probe: { _ in DoctorProbe(statusCode: 200, milliseconds: 12) },
                                logFinding: { _ in .none },
                                url: { URL(string: $0.url)! }))
    }

    func testTheToolExistsInReadOnlyMode() {
        XCTAssertTrue(doctorTools(daemon(), readOnly: true).toolNames.contains("doctor"))
    }

    func testOneSiteReportsItsChecks() async throws {
        let json = try await answer(doctorTools(daemon(statusWithFPM())), "doctor",
                                    .object(["site": .string("shop")]))
        XCTAssertEqual(json["site"]?.string, "shop")
        let sites = try XCTUnwrap(json["sites"]?.array)
        XCTAssertEqual(sites.first?["site"]?.string, "shop")
        let checks = try XCTUnwrap(sites.first?["checks"]?.array)
        XCTAssertEqual(checks.first { $0["id"]?.string == "http" }?["outcome"]?.string, "passed")
        XCTAssertEqual(checks.first { $0["id"]?.string == "http" }?["fix"]?.string, nil)
        let daemon = json["global"]?.array?.first { $0["id"]?.string == "daemon" }
        XCTAssertEqual(daemon?["outcome"]?.string, "passed")
        XCTAssertEqual(checks.first { $0["id"]?.string == "folder" }?["title"]?.string,
                       "The site folder is readable")
    }

    func testAWholePathFindsItsSite() async throws {
        let json = try await answer(doctorTools(daemon(statusWithFPM())), "doctor",
                                    .object(["path": .string(shopPath)]))
        XCTAssertEqual(json["sites"]?.array?.first?["site"]?.string, "shop")
    }

    func testNoArgumentsChecksEverySite() async throws {
        let json = try await answer(doctorTools(daemon(statusWithFPM())), "doctor")
        XCTAssertEqual(json["site"], JSONValue.null)
        XCTAssertEqual(json["sites"]?.array?.count, 2)
        let global = try XCTUnwrap(json["global"]?.array)
        XCTAssertFalse(global.isEmpty)
        let daemon = global.first { $0["id"]?.string == "daemon" }
        XCTAssertEqual(daemon?["outcome"]?.string, "passed")
        for site in json["sites"]?.array ?? [] {
            let checks = site["checks"]?.array
            XCTAssertFalse(checks?.isEmpty ?? true, "\(site)")
        }
    }

    func testBothArgumentsAreAFailure() async throws {
        let result = try await call(doctorTools(daemon()), "doctor",
                                    .object(["site": .string("shop"), "path": .string(shopPath)]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Give \"site\" or \"path\", not both."), result.text)
    }

    func testAnUnknownSiteIsAFailure() async throws {
        let result = try await call(doctorTools(daemon()), "doctor", .object(["site": .string("nope")]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("doesn't serve a site named \"nope\""), result.text)
    }
}
