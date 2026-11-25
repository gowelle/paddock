import ArgumentParser
import Foundation
import PaddockCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check every step from a request to a site, and say what is wrong.")

    @Argument(help: "A site's name or host; every site when left out.") var site: String?

    func run() throws {
        let status: EngineStatus
        do {
            switch try CLI.client.send(.status, timeout: 10) {
            case .ok(let answer), .removed(_, let answer), .databaseCreated(_, _, let answer):
                status = answer
            case .error(_, let message):
                throw CLI.failure(message)
            case .catalog, .envLines:
                throw CLI.unexpectedAnswer()
            }
        } catch let code as ExitCode {
            throw code
        } catch ClientError.daemonNotRunning {
            try finish(.unreachable(Messages.daemonNotRunning))
        } catch ClientError.timedOut {
            try finish(.unreachable(Messages.didNotAnswer))
        } catch ClientError.developmentBuild {
            try finish(.unreachable(Messages.developmentBuild))
        } catch {
            try finish(.unreachable(Messages.unexpectedAnswer(error)))
        }

        let named = try site.map { try CLI.site(named: $0, in: status).name }
        let report = makeReport(for: status, site: named)
        print(DoctorText.lines(for: report, site: named).joined(separator: "\n"))
        if !report.isHealthy { throw ExitCode.failure }
    }

    /// Prints an unreachable-daemon report and ends with the failure exit code.
    private func finish(_ report: DoctorReport) throws -> Never {
        print(DoctorText.lines(for: report).joined(separator: "\n"))
        throw ExitCode.failure
    }

    /// `Doctor.report` is async; ArgumentParser's command is not, so this bridges it like `paddock mcp` does.
    private func makeReport(for status: EngineStatus, site: String?) -> DoctorReport {
        final class Box: @unchecked Sendable { var report: DoctorReport? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            box.report = await Doctor().report(for: status, site: site)
            finished.signal()
        }
        finished.wait()
        return box.report ?? .unreachable(Messages.didNotAnswer)
    }
}
