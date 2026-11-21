import Darwin
import Foundation

/// One download a recipe needs, and how to unpack it into the recipe's `{bin}` folder.
public struct RecipeAsset: Codable, Equatable, Sendable {
    public let artifact: Artifact
    /// `tar.gz`, `tar.xz`, `zip` or `binary` (a single program, saved as `installAs`).
    public let archive: String
    /// Leading path components dropped when unpacking an archive.
    public let stripComponents: Int
    /// The file name of a `binary` asset inside `{bin}`.
    public let installAs: String?

    public init(artifact: Artifact, archive: String, stripComponents: Int = 0, installAs: String? = nil) {
        self.artifact = artifact
        self.archive = archive
        self.stripComponents = stripComponents
        self.installAs = installAs
    }

    private enum CodingKeys: String, CodingKey { case artifact, archive, stripComponents, installAs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artifact = try c.decode(Artifact.self, forKey: .artifact)
        archive = try c.decode(String.self, forKey: .archive)
        stripComponents = try c.decodeIfPresent(Int.self, forKey: .stripComponents) ?? 0
        installAs = try c.decodeIfPresent(String.self, forKey: .installAs)
    }
}

/// A program a recipe runs. Every string is a `ServiceTemplate`; each argument stays one argument.
public struct RecipeCommand: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    /// Written to the program's standard input, then closed.
    public let stdin: String?

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:],
                stdin: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdin = stdin
    }

    private enum CodingKeys: String, CodingKey { case executable, arguments, environment, stdin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        stdin = try c.decodeIfPresent(String.self, forKey: .stdin)
    }
}

/// A TCP port a service listens on, by name (`main`, `http`, `smtp`…), and the port it would like.
public struct RecipePort: Codable, Equatable, Sendable {
    public let name: String
    public let preferred: Int

    public init(name: String, preferred: Int) {
        self.name = name
        self.preferred = preferred
    }
}

/// How Paddock tells a started service is ready. Each value is a template.
public enum Readiness: Codable, Equatable, Sendable {
    /// 127.0.0.1 accepts a connection on this port (e.g. `{port.main}`).
    case tcp(port: String)
    /// The Unix socket at this path accepts a connection.
    case unixSocket(path: String)
    /// A GET of this loopback URL answers with `expectStatus`.
    case http(url: String, expectStatus: Int)

    /// How long a service may take to become ready before it counts as crashed.
    public static let deadline: TimeInterval = 30

    /// The template the probe renders.
    public var template: String {
        switch self {
        case .tcp(let port): return port
        case .unixSocket(let path): return path
        case .http(let url, _): return url
        }
    }
}

/// How to download, initialise, run and use one version of a service. Data, not code: the bundled
/// `services-catalog.json` holds one per service version, and `ServiceManager` runs any of them.
public struct ServiceRecipe: Codable, Equatable, Sendable {
    public let kind: String
    public let displayName: String
    public let version: String
    public let licence: String
    public let minimumMacOS: String?
    public let assets: [RecipeAsset]
    /// Run once, in order, when an instance's data folder is new.
    public let initialise: [RecipeCommand]
    public let start: RecipeCommand
    public let ready: Readiness
    /// `TERM`, `INT` or `QUIT`: what stops the service cleanly.
    public let stopSignal: String
    /// Seconds between the stop signal and SIGKILL.
    public let stopGraceSeconds: Int
    public let ports: [RecipePort]
    /// The service's Unix socket (a template, normally under `{run}`), if it has one.
    public let socket: String?
    /// `.env` lines for a Laravel app (templates).
    public let env: [String]
    /// The service's own page, if it has one (a template).
    public let openURL: String?
    /// Whether the service runs on Paddock's PHP (`{php}`).
    public let needsPHP: Bool

    public init(kind: String, displayName: String, version: String, licence: String, minimumMacOS: String? = nil,
                assets: [RecipeAsset], initialise: [RecipeCommand] = [], start: RecipeCommand, ready: Readiness,
                stopSignal: String = "TERM", stopGraceSeconds: Int = 10, ports: [RecipePort],
                socket: String? = nil, env: [String] = [], openURL: String? = nil, needsPHP: Bool = false) {
        self.kind = kind
        self.displayName = displayName
        self.version = version
        self.licence = licence
        self.minimumMacOS = minimumMacOS
        self.assets = assets
        self.initialise = initialise
        self.start = start
        self.ready = ready
        self.stopSignal = stopSignal
        self.stopGraceSeconds = stopGraceSeconds
        self.ports = ports
        self.socket = socket
        self.env = env
        self.openURL = openURL
        self.needsPHP = needsPHP
    }

    private enum CodingKeys: String, CodingKey {
        case kind, displayName, version, licence, minimumMacOS, assets, initialise, start, ready, stopSignal
        case stopGraceSeconds, ports, socket, env, openURL, needsPHP
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        displayName = try c.decode(String.self, forKey: .displayName)
        version = try c.decode(String.self, forKey: .version)
        licence = try c.decode(String.self, forKey: .licence)
        minimumMacOS = try c.decodeIfPresent(String.self, forKey: .minimumMacOS)
        assets = try c.decodeIfPresent([RecipeAsset].self, forKey: .assets) ?? []
        initialise = try c.decodeIfPresent([RecipeCommand].self, forKey: .initialise) ?? []
        start = try c.decode(RecipeCommand.self, forKey: .start)
        ready = try c.decode(Readiness.self, forKey: .ready)
        stopSignal = try c.decodeIfPresent(String.self, forKey: .stopSignal) ?? "TERM"
        stopGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .stopGraceSeconds) ?? 10
        ports = try c.decodeIfPresent([RecipePort].self, forKey: .ports) ?? []
        socket = try c.decodeIfPresent(String.self, forKey: .socket)
        env = try c.decodeIfPresent([String].self, forKey: .env) ?? []
        openURL = try c.decodeIfPresent(String.self, forKey: .openURL)
        needsPHP = try c.decodeIfPresent(Bool.self, forKey: .needsPHP) ?? false
    }

    /// The signal `stopSignal` names; SIGTERM for anything else.
    public var signalNumber: Int32 {
        switch stopSignal.uppercased() {
        case "INT": return SIGINT
        case "QUIT": return SIGQUIT
        default: return SIGTERM
        }
    }

    /// A copy with other preferred ports (`ServicePorts.shifted`).
    func withPorts(_ ports: [RecipePort]) -> ServiceRecipe {
        ServiceRecipe(kind: kind, displayName: displayName, version: version, licence: licence,
                      minimumMacOS: minimumMacOS, assets: assets, initialise: initialise, start: start, ready: ready,
                      stopSignal: stopSignal, stopGraceSeconds: stopGraceSeconds, ports: ports, socket: socket,
                      env: env, openURL: openURL, needsPHP: needsPHP)
    }
}
