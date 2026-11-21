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

    public static let archiveTypes: Set<String> = ["tar.gz", "tar.xz", "zip", "binary"]

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

/// One element of a command's arguments. In JSON either a string (a template, always one argument), or
/// `{"ifSocket": ["--socket", "{socket}"]}`: those arguments only when the instance has a usable Unix socket
/// (some programs reject an empty socket argument), dropped entirely otherwise.
public enum RecipeArgument: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    case plain(String)
    case ifSocket([String])

    public init(stringLiteral value: String) { self = .plain(value) }

    private enum CodingKeys: String, CodingKey { case ifSocket }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .plain(text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .ifSocket(try c.decode([String].self, forKey: .ifSocket))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .plain(let text):
            var c = encoder.singleValueContainer()
            try c.encode(text)
        case .ifSocket(let arguments):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(arguments, forKey: .ifSocket)
        }
    }

    /// Every template in it.
    var templates: [String] {
        switch self {
        case .plain(let text): return [text]
        case .ifSocket(let arguments): return arguments
        }
    }
}

/// A program a recipe runs. Every string is a `ServiceTemplate`; each argument stays one argument. The
/// program gets a small fixed environment (`ServiceManager.baseEnvironment`) plus `environment`, never
/// Paddock's own.
public struct RecipeCommand: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [RecipeArgument]
    public let environment: [String: String]
    /// Written to the program's standard input, then closed. Steps only, never the start command.
    public let stdin: String?

    public init(executable: String, arguments: [RecipeArgument] = [], environment: [String: String] = [:],
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
        arguments = try c.decodeIfPresent([RecipeArgument].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        stdin = try c.decodeIfPresent(String.self, forKey: .stdin)
    }
}

/// A command with every template rendered and conditional arguments resolved.
public struct RenderedCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let stdin: String?
}

/// A file Paddock writes for a service (both templates): before initialise, and again on every start.
public struct RecipeFile: Codable, Equatable, Sendable {
    /// Under `{config}/`.
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
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

    /// How long a service may take to become ready, unless its recipe says otherwise.
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
/// `services-catalog.json` holds one per service version, and `ServiceManager` runs any of them. The catalog
/// is validated as a whole when it is loaded (`ServiceCatalog.validate`).
public struct ServiceRecipe: Codable, Equatable, Sendable {
    public let kind: String
    public let displayName: String
    public let version: String
    /// The line within which data stays compatible and patches are drop-in: `18` for PostgreSQL 18.x,
    /// `8.4` for MySQL 8.4.x, `1` for Mailpit 1.x. Instances are tied to a series, not a version.
    public let series: String
    /// Whether instance ids and names carry the series (`postgres-18`, `PostgreSQL 18`). False for kinds
    /// with one line users care about (`mail`, `Mail`).
    public let seriesInID: Bool
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
    /// The service's Unix socket (a template under `{run}/`), if it has one.
    public let socket: String?
    /// `.env` lines for a Laravel app (templates).
    public let env: [String]
    /// The service's own page, if it has one (a template).
    public let openURL: String?
    /// Whether the service runs on Paddock's PHP (`{php}`).
    public let needsPHP: Bool
    /// Files under `{config}/` written before initialise and on every start.
    public let configFiles: [RecipeFile]
    /// Seconds the service may take to become ready (default 30).
    public let readyTimeoutSeconds: Int?
    /// Seconds each initialise step may take (default 120).
    public let initialiseTimeoutSeconds: Int?

    public static let defaultInitialiseTimeout: TimeInterval = 120

    public init(kind: String, displayName: String, version: String, series: String? = nil, seriesInID: Bool = true,
                licence: String, minimumMacOS: String? = nil, assets: [RecipeAsset], initialise: [RecipeCommand] = [],
                start: RecipeCommand, ready: Readiness, stopSignal: String = "TERM", stopGraceSeconds: Int = 10,
                ports: [RecipePort], socket: String? = nil, env: [String] = [], openURL: String? = nil,
                needsPHP: Bool = false, configFiles: [RecipeFile] = [], readyTimeoutSeconds: Int? = nil,
                initialiseTimeoutSeconds: Int? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.version = version
        self.series = series ?? Self.leadingComponent(of: version)
        self.seriesInID = seriesInID
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
        self.configFiles = configFiles
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.initialiseTimeoutSeconds = initialiseTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case kind, displayName, version, series, seriesInID, licence, minimumMacOS, assets, initialise, start, ready
        case stopSignal, stopGraceSeconds, ports, socket, env, openURL, needsPHP, configFiles, readyTimeoutSeconds
        case initialiseTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        displayName = try c.decode(String.self, forKey: .displayName)
        version = try c.decode(String.self, forKey: .version)
        series = try c.decode(String.self, forKey: .series)
        seriesInID = try c.decodeIfPresent(Bool.self, forKey: .seriesInID) ?? true
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
        configFiles = try c.decodeIfPresent([RecipeFile].self, forKey: .configFiles) ?? []
        readyTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .readyTimeoutSeconds)
        initialiseTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .initialiseTimeoutSeconds)
    }

    /// The signal `stopSignal` names; SIGTERM for anything else.
    public var signalNumber: Int32 {
        switch stopSignal.uppercased() {
        case "INT": return SIGINT
        case "QUIT": return SIGQUIT
        default: return SIGTERM
        }
    }

    public var readyTimeout: TimeInterval { readyTimeoutSeconds.map(TimeInterval.init) ?? Readiness.deadline }
    public var initialiseTimeout: TimeInterval {
        initialiseTimeoutSeconds.map(TimeInterval.init) ?? Self.defaultInitialiseTimeout
    }

    /// `18.1` -> `18`.
    static func leadingComponent(of version: String) -> String {
        version.split(whereSeparator: { $0 == "." || $0 == "-" }).first.map(String.init) ?? version
    }

    /// A copy with other downloads (tests serve them from a local cache).
    func withAssets(_ assets: [RecipeAsset]) -> ServiceRecipe {
        copy(assets: assets, ports: ports)
    }

    /// A copy with other preferred ports (`ServicePorts.shifted`).
    func withPorts(_ ports: [RecipePort]) -> ServiceRecipe {
        copy(assets: assets, ports: ports)
    }

    private func copy(assets: [RecipeAsset], ports: [RecipePort]) -> ServiceRecipe {
        ServiceRecipe(kind: kind, displayName: displayName, version: version, series: series, seriesInID: seriesInID,
                      licence: licence, minimumMacOS: minimumMacOS, assets: assets, initialise: initialise,
                      start: start, ready: ready, stopSignal: stopSignal, stopGraceSeconds: stopGraceSeconds,
                      ports: ports, socket: socket, env: env, openURL: openURL, needsPHP: needsPHP,
                      configFiles: configFiles, readyTimeoutSeconds: readyTimeoutSeconds,
                      initialiseTimeoutSeconds: initialiseTimeoutSeconds)
    }
}
