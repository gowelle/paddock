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

/// A value an action takes from the user (`{database}`), and the whole-value pattern it must match.
public struct RecipeParameter: Codable, Equatable, Sendable {
    /// Its placeholder name: lowercase letters, digits and underscores, not a name Paddock already uses.
    public let name: String
    /// A regular expression anchored with `^` and `$`.
    public let pattern: String

    public init(name: String, pattern: String) {
        self.name = name
        self.pattern = pattern
    }
}

/// Something a recipe does to its running service, by name: `createDatabase` on request (and, later, steps
/// after it is ready). Its command runs like an initialise step: through the bounded step runner, in the
/// instance's folder, with the service environment, its program inside the recipe's binaries. Its parameters
/// are bound only for its arguments (and `alreadyDone`), never its program, environment or input, and every
/// value is checked against the parameter's pattern before anything runs.
public struct RecipeAction: Codable, Equatable, Sendable {
    public static let createDatabase = "createDatabase"
    /// The actions Paddock knows how to ask for.
    public static let names: Set<String> = [createDatabase]
    public static let defaultTimeout: TimeInterval = 60

    public let command: RecipeCommand
    public let parameters: [RecipeParameter]
    /// Output (a template) that, from a command that exits with an error, means there was nothing to do (the
    /// database is there already): reported as already done, not as a failure.
    public let alreadyDone: String?
    /// Seconds the command may take (default 60).
    public let timeoutSeconds: Int?

    public init(command: RecipeCommand, parameters: [RecipeParameter] = [], alreadyDone: String? = nil,
                timeoutSeconds: Int? = nil) {
        self.command = command
        self.parameters = parameters
        self.alreadyDone = alreadyDone
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey { case command, parameters, alreadyDone, timeoutSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(RecipeCommand.self, forKey: .command)
        parameters = try c.decodeIfPresent([RecipeParameter].self, forKey: .parameters) ?? []
        alreadyDone = try c.decodeIfPresent(String.self, forKey: .alreadyDone)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }

    public var timeout: TimeInterval { timeoutSeconds.map(TimeInterval.init) ?? Self.defaultTimeout }
}

/// A command with every template rendered and conditional arguments resolved.
public struct RenderedCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let stdin: String?
}

/// A file Paddock writes for a service (both templates): before initialise, and again on every start. Its
/// lines that use `{socket}` or `{socketDir}` are left out when the instance has no usable socket.
public struct RecipeFile: Codable, Equatable, Sendable {
    /// Under `{config}/`.
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// A random value Paddock makes for each instance (a master key) the first time it needs it, and keeps with
/// the instance (`config/secrets.json`). Recipes use it as `{secret.<name>}`, only in a command's environment
/// and in the `.env` lines: never in arguments (anyone can see those in `ps`), paths, config files or URLs.
public struct RecipeSecret: Codable, Equatable, Sendable {
    /// Lowercase letters, digits and underscores (`master_key`).
    public let name: String
    /// How many random bytes (16 to 64); stored URL-safe base64 without padding.
    public let bytes: Int

    public init(name: String, bytes: Int) {
        self.name = name
        self.bytes = bytes
    }
}

/// A sentence Paddock adds to a failed start when the log shows a known cause (Valkey's "Can't handle RDB
/// format version": data from a newer version). Plain text, not templates.
public struct RecipeLogHint: Codable, Equatable, Sendable {
    /// Text the end of the log contains.
    public let contains: String
    /// What it means for the user, as a sentence.
    public let hint: String

    public init(contains: String, hint: String) {
        self.contains = contains
        self.hint = hint
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
public enum Readiness: Equatable, Sendable {
    /// 127.0.0.1 accepts a connection on this port (e.g. `{port.main}`).
    case tcp(port: String)
    /// The Unix socket at this path accepts a connection.
    case unixSocket(path: String)
    /// A GET of this loopback URL answers with `expectStatus`.
    case http(url: String, expectStatus: Int)
    /// This command exits 0 (PostgreSQL's `pg_isready`): run like a step, under the same rules as every
    /// other command, a few seconds at most per attempt, again and again until the deadline.
    case command(RecipeCommand)

    /// How long a service may take to become ready, unless its recipe says otherwise.
    public static let deadline: TimeInterval = 30

    /// The template a probe renders (the program, for a command).
    public var template: String {
        switch self {
        case .tcp(let port): return port
        case .unixSocket(let path): return path
        case .http(let url, _): return url
        case .command(let command): return command.executable
        }
    }

    /// The command a `.command` probe runs.
    public var command: RecipeCommand? {
        if case .command(let command) = self { return command }
        return nil
    }
}

/// The JSON forms: `{"tcp":{"port":…}}`, `{"unixSocket":{"path":…}}`, `{"http":{"url":…,"expectStatus":…}}`
/// and `{"command":{"executable":…,"arguments":[…]}}`.
extension Readiness: Codable {
    private enum Kind: String, CodingKey { case tcp, unixSocket, http, command }
    private enum Field: String, CodingKey { case port, path, url, expectStatus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Kind.self)
        guard c.allKeys.count == 1, let kind = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "readiness needs exactly one of tcp, unixSocket, http or command"))
        }
        switch kind {
        case .tcp:
            self = .tcp(port: try c.nestedContainer(keyedBy: Field.self, forKey: .tcp).decode(String.self, forKey: .port))
        case .unixSocket:
            self = .unixSocket(path: try c.nestedContainer(keyedBy: Field.self, forKey: .unixSocket)
                .decode(String.self, forKey: .path))
        case .http:
            let http = try c.nestedContainer(keyedBy: Field.self, forKey: .http)
            self = .http(url: try http.decode(String.self, forKey: .url), expectStatus: try http.decode(Int.self, forKey: .expectStatus))
        case .command:
            self = .command(try c.decode(RecipeCommand.self, forKey: .command))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Kind.self)
        switch self {
        case .tcp(let port):
            var tcp = c.nestedContainer(keyedBy: Field.self, forKey: .tcp)
            try tcp.encode(port, forKey: .port)
        case .unixSocket(let path):
            var socket = c.nestedContainer(keyedBy: Field.self, forKey: .unixSocket)
            try socket.encode(path, forKey: .path)
        case .http(let url, let expectStatus):
            var http = c.nestedContainer(keyedBy: Field.self, forKey: .http)
            try http.encode(url, forKey: .url)
            try http.encode(expectStatus, forKey: .expectStatus)
        case .command(let command):
            try c.encode(command, forKey: .command)
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
    /// Steps run once, after the instance's first start that became ready (creating a default bucket, say). Run
    /// like initialise steps, against the running service. Each must be safe to run again: a marker in the
    /// instance's config folder records that they ran, and an instance whose config folder is new runs them
    /// again on data that may already have been set up.
    public let afterReady: [RecipeCommand]
    public let start: RecipeCommand
    public let ready: Readiness
    /// `TERM`, `INT` or `QUIT`: what stops the service cleanly.
    public let stopSignal: String
    /// Seconds between the stop signal and SIGKILL.
    public let stopGraceSeconds: Int
    public let ports: [RecipePort]
    /// The service's Unix socket, if it has one: `{run}/` and one file name, literal but for `{port.<name>}`
    /// (`{run}/.s.PGSQL.{port.main}`). Rendered as `{socket}` (and its folder as `{socketDir}`), or as nothing
    /// when the path would be too long for macOS.
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
    /// What it can do on request while it runs, by name (`RecipeAction.names`).
    public let actions: [String: RecipeAction]
    /// Files whose first line is the pid of the process holding them (PostgreSQL's `postmaster.pid`).
    public let lockFiles: [String]
    /// Short sentences shown beside the service (`Includes PostGIS 3.6.4 (no raster or topology).`).
    public let notes: [String]
    /// Sentences added to a failed start whose log shows a known cause.
    public let logHints: [RecipeLogHint]
    /// Random values made once per instance (`{secret.<name>}`).
    public let secrets: [RecipeSecret]

    public static let defaultInitialiseTimeout: TimeInterval = 120

    public init(kind: String, displayName: String, version: String, series: String? = nil, seriesInID: Bool = true,
                licence: String, minimumMacOS: String? = nil, assets: [RecipeAsset], initialise: [RecipeCommand] = [],
                start: RecipeCommand, ready: Readiness, stopSignal: String = "TERM", stopGraceSeconds: Int = 10,
                ports: [RecipePort], socket: String? = nil, env: [String] = [], openURL: String? = nil,
                needsPHP: Bool = false, configFiles: [RecipeFile] = [], readyTimeoutSeconds: Int? = nil,
                initialiseTimeoutSeconds: Int? = nil, actions: [String: RecipeAction] = [:], lockFiles: [String] = [],
                notes: [String] = [], logHints: [RecipeLogHint] = [], secrets: [RecipeSecret] = [],
                afterReady: [RecipeCommand] = []) {
        self.kind = kind
        self.displayName = displayName
        self.version = version
        self.series = series ?? Self.leadingComponent(of: version)
        self.seriesInID = seriesInID
        self.licence = licence
        self.minimumMacOS = minimumMacOS
        self.assets = assets
        self.initialise = initialise
        self.afterReady = afterReady
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
        self.actions = actions
        self.lockFiles = lockFiles
        self.notes = notes
        self.logHints = logHints
        self.secrets = secrets
    }

    private enum CodingKeys: String, CodingKey {
        case kind, displayName, version, series, seriesInID, licence, minimumMacOS, assets, initialise, start, ready
        case stopSignal, stopGraceSeconds, ports, socket, env, openURL, needsPHP, configFiles, readyTimeoutSeconds
        case initialiseTimeoutSeconds, actions, lockFiles, notes, logHints, secrets, afterReady
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
        afterReady = try c.decodeIfPresent([RecipeCommand].self, forKey: .afterReady) ?? []
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
        actions = try c.decodeIfPresent([String: RecipeAction].self, forKey: .actions) ?? [:]
        lockFiles = try c.decodeIfPresent([String].self, forKey: .lockFiles) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        logHints = try c.decodeIfPresent([RecipeLogHint].self, forKey: .logHints) ?? []
        secrets = try c.decodeIfPresent([RecipeSecret].self, forKey: .secrets) ?? []
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
                      initialiseTimeoutSeconds: initialiseTimeoutSeconds, actions: actions, lockFiles: lockFiles, notes: notes,
                      logHints: logHints, secrets: secrets, afterReady: afterReady)
    }
}
