import Combine
import Foundation
import PaddockCore
import SwiftUI

struct SiteHealth: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case checking
        case healthy
        case warning
        case unreachable
        case stopped

        var label: String {
            switch self {
            case .checking: return "Checking"
            case .healthy: return "Healthy"
            case .warning: return "Warning"
            case .unreachable: return "Unreachable"
            case .stopped: return "Stopped"
            }
        }

        var color: Color {
            switch self {
            case .checking: return Theme.inkMuted
            case .healthy: return Theme.pasture
            case .warning: return Theme.honeyText
            case .unreachable: return .red
            case .stopped: return Theme.inkMuted
            }
        }
    }

    let tone: Tone
    let detail: String
}

@MainActor
final class SiteHealthModel: ObservableObject {
    @Published private(set) var entries: [String: SiteHealth] = [:]
    private var refreshTask: Task<Void, Never>?

    func refresh(sites: [Site], isServing: Bool) {
        refreshTask?.cancel()

        let names = Set(sites.map(\.name))
        entries = entries.filter { names.contains($0.key) }

        if !isServing {
            entries = Dictionary(uniqueKeysWithValues: sites.map {
                ($0.name, SiteHealth(tone: .stopped, detail: "Paddock is not serving"))
            })
            return
        }

        for site in sites {
            entries[site.name] = SiteHealth(tone: .checking, detail: "Checking…")
        }

        refreshTask = Task {
            await withTaskGroup(of: (String, SiteHealth).self) { group in
                for site in sites {
                    group.addTask {
                        await Self.probe(site)
                    }
                }

                for await (name, health) in group {
                    if !Task.isCancelled { entries[name] = health }
                }
            }
        }
    }

    private static func probe(_ site: Site) async -> (String, SiteHealth) {
        guard let url = URL(string: site.url) else {
            return (site.name, SiteHealth(tone: .unreachable, detail: "Invalid address"))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3

        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let milliseconds = max(1, Int(Date().timeIntervalSince(started) * 1000))
            guard let http = response as? HTTPURLResponse else {
                return (site.name, SiteHealth(tone: .unreachable, detail: "No HTTP response"))
            }

            if (200...499).contains(http.statusCode) {
                let tone: SiteHealth.Tone = (400...499).contains(http.statusCode) ? .warning : .healthy
                return (site.name, SiteHealth(tone: tone,
                                              detail: "HTTP \(http.statusCode) · \(milliseconds) ms"))
            }
            return (site.name, SiteHealth(tone: .unreachable,
                                          detail: "HTTP \(http.statusCode) · \(milliseconds) ms"))
        } catch {
            return (site.name, SiteHealth(tone: .unreachable, detail: "No response"))
        }
    }
}

struct SiteHealthBadge: View {
    let health: SiteHealth?

    var body: some View {
        let value = health ?? SiteHealth(tone: .checking, detail: "Checking…")
        HStack(spacing: 6) {
            if value.tone == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(value.tone.color).frame(width: 7, height: 7)
            }
            Text(value.detail)
                .font(.caption)
                .foregroundStyle(value.tone == .healthy ? Theme.ink : Theme.inkMuted)
                .lineLimit(1)
        }
        .help(value.detail)
    }
}
