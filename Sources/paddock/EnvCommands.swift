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
