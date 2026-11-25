import Foundation

extension MCPTools {
    /// The `doctor` tool: resolve the site the arguments name, diagnose, and answer as JSON.
    func diagnose(_ arguments: JSONValue) async throws -> MCPToolResult {
        let name = try arguments.optionalText("site"), path = try arguments.optionalText("path")
        let status = try currentStatus()
        let named: String?
        switch (name, path) {
        case (let name?, nil):
            named = try site(named: name, in: status).name
        case (nil, let path?):
            named = try site(containing: path, in: status).name
        case (nil, nil):
            named = nil
        default:
            throw MCPFailure("Give \"site\" or \"path\", not both.")
        }
        let report = await doctor.report(for: status, site: named)
        return .ok(Self.json(report, site: named))
    }

    static func json(_ check: DoctorCheck) -> JSONValue {
        .object([
            "id": .string(check.id),
            "title": .string(check.title),
            "outcome": .string(check.outcome.rawValue),
            "detail": .string(check.detail),
            "fix": check.fix.map(JSONValue.string) ?? .null,
        ])
    }

    static func json(_ report: DoctorReport, site: String?) -> JSONValue {
        .object([
            "site": site.map(JSONValue.string) ?? .null,
            "global": .array(report.global.map(json)),
            "sites": .array(report.sites.map { one in
                .object([
                    "site": .string(one.site),
                    "checks": .array(one.checks.map(json)),
                ])
            }),
        ])
    }
}
