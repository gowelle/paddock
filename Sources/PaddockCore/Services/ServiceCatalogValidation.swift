import Foundation

extension ServiceCatalog {
    /// Placeholders every recipe may use; `{port.<name>}` for each of its own ports comes on top.
    static let knownPlaceholders: Set<String> = ["bin", "data", "config", "run", "log", "name", "id", "socket", "php",
                                                 "resources"]
    static let stopSignals: Set<String> = ["TERM", "INT", "QUIT"]
    /// Environment names a recipe may set only to a path inside the instance's own folders.
    static let pathVariables: Set<String> = ["PATH", "HOME", "TMPDIR"]

    /// Checks a whole catalog before anything uses it; throws `ServiceCatalogError.invalid` naming the
    /// first problem. Kinds, series and versions are safe in paths; every program runs from the recipe's
    /// binaries (or Paddock's PHP); environment, socket and config files stay inside the instance's folders;
    /// every placeholder is known; signals, archives, file names and ports make sense; and no recipe is
    /// listed twice.
    public static func validate(_ recipes: [ServiceRecipe]) throws {
        var seen: Set<String> = []
        for recipe in recipes {
            try validate(recipe)
            let key = "\(recipe.kind) \(recipe.series) \(recipe.version)"
            guard seen.insert(key).inserted else {
                throw ServiceCatalogError.invalid("\(recipe.kind) \(recipe.version) is listed more than once")
            }
        }
    }

    private static func validate(_ recipe: ServiceRecipe) throws {
        let label = "\(recipe.kind) \(recipe.version)"
        func fail(_ problem: String) -> ServiceCatalogError { .invalid("\(label): \(problem)") }

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
                if name.hasPrefix("DYLD_") { throw fail("the environment may not set \(name) (DYLD_ variables)") }
                if pathVariables.contains(name), !isInsideInstance(value) {
                    throw fail("\(name) may only be set to a path inside the instance's {data}, {config} or {run}")
                }
            }
        }

        // Where it writes.
        if let socket = recipe.socket, !isUnder("{run}/", socket) {
            throw fail("the socket \(socket) must be a file under {run}/")
        }
        for file in recipe.configFiles where !isUnder("{config}/", file.path) {
            throw fail("the config file \(file.path) must be a file under {config}/")
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

    /// `prefix` followed by at least one path component, none of them `.`, `..` or empty.
    private static func isUnder(_ prefix: String, _ path: String) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let rest = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return !rest.isEmpty && rest.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func runsFromBinariesOrPHP(_ executable: String) -> Bool {
        executable == "{php}" || isUnder("{bin}/", executable)
    }

    /// `{data}`, `{config}` or `{run}`, or a path under one of them.
    private static func isInsideInstance(_ value: String) -> Bool {
        ["{data}", "{config}", "{run}"].contains { value == $0 || isUnder($0 + "/", value) }
    }
}
