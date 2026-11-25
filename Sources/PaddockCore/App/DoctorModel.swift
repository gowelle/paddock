import Combine
import Foundation

/// The Doctor window's state: the sites to choose from, the site chosen, and the last report.
@MainActor
public final class DoctorModel: ObservableObject {
    public typealias StatusFetcher = @Sendable () async throws -> EngineStatus
    public typealias Diagnoser = @Sendable (EngineStatus, String?) async -> DoctorReport

    @Published public private(set) var sites: [Site] = []
    /// Nil means every site.
    @Published public var target: String?
    @Published public private(set) var report: DoctorReport?
    @Published public private(set) var isChecking = false
    /// The status failure's sentence, also shown as the daemon row; nil after a successful check.
    @Published public private(set) var error: String?

    private let fetchStatus: StatusFetcher
    private let diagnose: Diagnoser

    public init(fetchStatus: @escaping StatusFetcher,
                diagnose: @escaping Diagnoser = { status, site in
                    await Doctor().report(for: status, site: site)
                }) {
        self.fetchStatus = fetchStatus
        self.diagnose = diagnose
    }

    /// A fresh status, then a fresh report. A failed fetch becomes the daemon row, never a blank error screen.
    public func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let status = try await fetchStatus()
            // The Doctor window's task is cancelled when the window closes; a cancelled probe must
            // not become a failed row, so drop the whole result.
            guard !Task.isCancelled else { return }
            let next = await diagnose(status, target)
            guard !Task.isCancelled else { return }
            sites = status.sites
            if let target, !status.sites.contains(where: { $0.name == target }) { self.target = nil }
            report = next
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            let sentence: String
            let clientError = error as? ClientError
            if clientError == .daemonNotRunning {
                sentence = Messages.daemonNotRunning
            } else if clientError == .timedOut {
                sentence = Messages.didNotAnswer
            } else if clientError == .developmentBuild {
                sentence = Messages.developmentBuild
            } else {
                sentence = Messages.unexpectedAnswer(error)
            }
            self.error = sentence
            report = .unreachable(sentence)
        }
    }
}
