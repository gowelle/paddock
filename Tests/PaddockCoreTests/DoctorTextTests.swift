import XCTest
@testable import PaddockCore

final class DoctorTextTests: XCTestCase {
    private func check(_ id: String, _ title: String, _ outcome: DoctorCheck.Outcome,
                       _ detail: String, fix: String? = nil) -> DoctorCheck {
        DoctorCheck(id: id, title: title, outcome: outcome, detail: detail, fix: fix)
    }

    private func siteReport(_ name: String, _ checks: [DoctorCheck]) -> DoctorReport.SiteReport {
        DoctorReport.SiteReport(site: name, host: "\(name).test",
                                php: PHPVersion(major: 8, minor: 5),
                                url: "https://\(name).test", checks: checks)
    }

    func testOneSiteWithAPassingHTTPSRowAndAnInfoLog() {
        let report = DoctorReport(global: [
            check("daemon", "The daemon answers (build 24)", .passed, "The daemon answers (build 24)."),
            check("ports", "Ports 80 and 443 are free", .passed, "Ports 80 and 443 are free."),
        ], sites: [siteReport("mysite", [
            check("http", "https://mysite.test answers", .passed, "HTTPS 200 in 24 ms."),
            check("log", "Newest error in the site's log", .info, "No errors in laravel.log."),
        ])])

        XCTAssertEqual(DoctorText.lines(for: report, site: "mysite"), [
            "mysite.test — PHP 8.5, https://mysite.test",
            "",
            "  ✓ The daemon answers (build 24).",
            "  ✓ Ports 80 and 443 are free.",
            "  ✓ https://mysite.test answers.",
            "  i Newest error in the site's log.",
            "      No errors in laravel.log.",
            "",
            "Everything checks out.",
        ])
    }

    func testFailingRowCarriesItsDetailAndFixAndASkippedRowItsDetail() {
        let report = DoctorReport(global: [
            check("dns", "DNS answers a site's host", .skipped, "No sites to resolve."),
        ], sites: [siteReport("mysite", [
            check("http", "https://mysite.test answers", .failed, "No answer within 5 seconds.",
                  fix: "paddock restart"),
        ])])

        XCTAssertEqual(DoctorText.lines(for: report, site: "mysite"), [
            "mysite.test — PHP 8.5, https://mysite.test",
            "",
            "  - DNS answers a site's host.",
            "      No sites to resolve.",
            "  ✗ https://mysite.test answers.",
            "      No answer within 5 seconds.",
            "      Fix: paddock restart",
            "",
            "1 check needs attention.",
        ])
    }

    func testAllSitesPrintsHealthySitesInOneLine() {
        let healthy = [siteReport("blog", [
            check("http", "http://blog.test answers", .passed, "HTTP 200 in 3 ms."),
        ])]
        let report = DoctorReport(global: [
            check("daemon", "The daemon answers (build 24)", .passed, "The daemon answers (build 24)."),
        ], sites: healthy)

        XCTAssertEqual(DoctorText.lines(for: report), [
            "Paddock",
            "",
            "  ✓ The daemon answers (build 24).",
            "",
            "blog.test: OK.",
            "",
            "Everything checks out.",
        ])
    }

    func testAllSitesSummarisesFailures() {
        let report = DoctorReport(global: [
            check("daemon", "The daemon answers (build 24)", .passed, "The daemon answers (build 24)."),
        ], sites: [
            siteReport("blog", [check("http", "http://blog.test answers", .passed, "HTTP 200 in 3 ms.")]),
            siteReport("shop", [check("folder", "The site folder is readable", .failed,
                                      "/Users/you/Sites/shop can't be read.")]),
        ])

        let lines = DoctorText.lines(for: report)
        XCTAssertTrue(lines.contains("blog.test: OK."), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("shop.test — PHP 8.5, https://shop.test"),
                      lines.joined(separator: "\n"))
        XCTAssertEqual(lines.last, "1 check needs attention.")
    }
}
