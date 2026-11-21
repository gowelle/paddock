import Foundation

extension ServiceCatalog {
    /// Placeholders every recipe may use; `{port.<name>}` for each of its own ports comes on top.
    static let knownPlaceholders: Set<String> = ["bin", "data", "config", "run", "log", "name", "id", "socket", "php",
                                                 "resources"]
    static let stopSignals: Set<String> = ["TERM", "INT", "QUIT"]
    /// Environment names a recipe may set only to a path inside the instance's own folders.
    static let pathVariables: Set<String> = ["HOME", "TMPDIR", "PHPRC", "PHP_INI_SCAN_DIR"]
    /// Environment names that change how a program loads code or parses its input: never set by a recipe.
    static let forbiddenVariables: Set<String> = ["RUBYOPT", "NODE_OPTIONS", "BASH_ENV", "ENV", "IFS", "CDPATH",
                                                  "GLOBIGNORE"]
    static let forbiddenPrefixes = ["DYLD_", "LD_", "PERL5", "PYTHON"]
    /// The folders an instance's own paths start from.
    static let instanceRoots = ["{data}", "{config}", "{run}"]

    /// Checks a whole catalog (or one stored recipe) before anything uses it; throws `ServiceCatalogError.invalid` naming the
    /// first problem. Kinds, series and versions are safe in paths; every program runs from the recipe's
    /// binaries (or Paddock's PHP); environment, socket and config files stay inside the instance's folders;
    /// every placeholder is known; signals, archives, file names and ports make sense; and no recipe is
    /// listed twice.
    public static func validate(_ recipes: [ServiceRecipe]) throws {
        var seen: Set<String> = []
        for recipe in recipes {
            try validate(recipe)
            // Binaries live per kind and version, so that pair is unique whatever the series.
            let key = "\(recipe.kind) \(recipe.version)"
            guard seen.insert(key).inserted else {
                throw ServiceCatalogError.invalid("\(recipe.kind) \(recipe.version) is listed more than once")
            }
        }
    }

    private static func validate(_ recipe: ServiceRecipe) throws {
        let label = "\(recipe.kind) \(recipe.version)"
        func fail(_ problem: String) -> ServiceCatalogError { .invalid("\(label): \(problem)") }

        guard ServiceInstance.isValidName(recipe.displayName) else {
            throw fail("the display name \"\(Messages.printable(recipe.displayName) ?? "")\" must be 1 to 64 printable "
                       + "characters without \"/\"")
        }
        guard ServiceInstance.isValidID(recipe.kind) else {
            throw fail("the kind \"\(recipe.kind)\" must be lowercase letters and digits joined by single dashes, and not \"bin\"")
        }
        for (field, value) in [("series", recipe.series), ("version", recipe.version)] where !isSafeName(value) {
            throw fail("the \(field) \"\(value)\" must be lowercase letters, digits, dots and dashes, without \"..\"")
        }

        // Programs.
        let commands = [recipe.start] + recipe.initialise
        for command in commands where !runsFromBinariesOrPHP(command.executable) {
            throw fail("\(command.executable) must be a program under {bin}/ or exactly {php}")
        }
        if recipe.start.stdin != nil { throw fail("only initialise steps may have stdin, not the start command") }
        for command in commands {
            for (name, value) in command.environment {
                guard name.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else {
                    throw fail("the environment name \"\(name)\" must be uppercase letters, digits and underscores")
                }
                if let prefix = forbiddenPrefixes.first(where: { name.hasPrefix($0) }) {
                    throw fail("the environment may not set \(name) (\(prefix) variables)")
                }
                if forbiddenVariables.contains(name) { throw fail("the environment may not set \(name)") }
                if pathVariables.contains(name), !isRootedPath(value, roots: instanceRoots, restRequired: false) {
                    throw fail("\(name) may only be set to {data}, {config} or {run}, or a literal path under one")
                }
                if name == "PATH", !value.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({
                    isRootedPath(String($0), roots: ["{bin}"] + instanceRoots, restRequired: false)
                }) {
                    throw fail("every PATH entry must be {bin}, {data}, {config} or {run}, or a literal path under one")
                }
            }
        }

        // Where it writes.
        if let socket = recipe.socket, !isRootedPath(socket, roots: ["{run}"], restRequired: true) {
            throw fail("the socket \(socket) must be {run}/ followed by a literal file name")
        }
        for file in recipe.configFiles where !isRootedPath(file.path, roots: ["{config}"], restRequired: true) {
            throw fail("the config file \(file.path) must be {config}/ followed by a literal path")
        }

        // Ports, signals, downloads.
        var portNames: Set<String> = []
        for port in recipe.ports {
            guard port.name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
                  portNames.insert(port.name).inserted else {
                throw fail("the port name \"\(port.name)\" must be unique, lowercase letters, digits and underscores")
            }
            guard (1024...65535).contains(port.preferred) else {
                throw fail("the port \(port.name) prefers \(port.preferred); it must be between 1024 and 65535")
            }
        }
        if !stopSignals.contains(recipe.stopSignal) { throw fail("the stop signal must be TERM, INT or QUIT") }
        if (recipe.readyTimeoutSeconds ?? 1) <= 0 || (recipe.initialiseTimeoutSeconds ?? 1) <= 0 {
            throw fail("timeouts must be positive")
        }
        for asset in recipe.assets {
            guard (0...8).contains(asset.stripComponents) else {
                throw fail("stripComponents must be between 0 and 8")
            }
            guard RecipeAsset.archiveTypes.contains(asset.archive) else {
                throw fail("the archive type \"\(asset.archive)\" must be one of tar.gz, tar.xz, zip or binary")
            }
            if asset.archive == "binary" && asset.installAs == nil {
                throw fail("a binary download needs installAs, a plain file name")
            }
            if let name = asset.installAs, !isPlainFileName(name) {
                throw fail("installAs \"\(name)\" must be a plain file name")
            }
            let fileName = BuildSource.fileName(asset.artifact.url) ?? asset.artifact.url.lastPathComponent
            guard isPlainFileName(fileName) else {
                throw fail("the download \(asset.artifact.url.absoluteString) does not end in a plain file name")
            }
        }

        // Placeholders.
        let known = knownPlaceholders.union(recipe.ports.map { "port.\($0.name)" })
        var templates = [recipe.ready.template] + recipe.env + [recipe.socket, recipe.openURL].compactMap { $0 }
        for command in commands {
            templates += [command.executable] + command.arguments.flatMap(\.templates) + Array(command.environment.values)
            templates += [command.stdin].compactMap { $0 }
        }
        templates += recipe.configFiles.flatMap { [$0.path, $0.contents] }
        for template in templates {
            if let unknown = ServiceTemplate.placeholders(in: template).first(where: { !known.contains($0) }) {
                throw fail("{\(unknown)} is not a placeholder Paddock knows")
            }
        }
    }

    /// `^[a-z0-9][a-z0-9.-]*$` without `..`.
    static func isSafeName(_ text: String) -> Bool {
        text.range(of: "^[a-z0-9][a-z0-9.-]*$", options: .regularExpression) != nil && !text.contains("..")
    }

    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// One of `roots` (a single leading folder placeholder), then only literal text: `/` and path components
    /// that are not empty, `.` or `..` and hold no placeholder. With `restRequired` the root alone isn't enough.
    /// `{name}` and other free text can therefore never steer a path.
    static func isRootedPath(_ value: String, roots: [String], restRequired: Bool) -> Bool {
        guard let root = roots.first(where: { value.hasPrefix($0) }) else { return false }
        let rest = value.dropFirst(root.count)
        if rest.isEmpty { return !restRequired }
        guard rest.hasPrefix("/"), ServiceTemplate.placeholders(in: String(rest)).isEmpty else { return false }
        return rest.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func runsFromBinariesOrPHP(_ executable: String) -> Bool {
        executable == "{php}" || isRootedPath(executable, roots: ["{bin}"], restRequired: true)
    }
}
