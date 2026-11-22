import Foundation

extension ServiceCatalog {
    /// Placeholders every recipe may use; `{port.<name>}` for each of its own ports comes on top.
    static let knownPlaceholders: Set<String> = ["bin", "data", "config", "run", "log", "name", "id", "socket",
                                                 "socketDir", "php", "resources"]
    static let stopSignals: Set<String> = ["TERM", "INT", "QUIT"]
    /// Environment names a recipe may set only to a path inside the instance's own folders.
    static let pathVariables: Set<String> = ["HOME", "TMPDIR", "PHPRC"]
    /// Environment names holding `:`-separated folders, each of which must be one of these roots or under it.
    /// A recipe's PATH comes before the base PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so it may name only
    /// folders the service can't write to itself: `{data}` or `{run}` could shadow `sh` for its children.
    static let folderListVariables: [String: [String]] = ["PATH": ["{bin}", "{config}"],
                                                          "PHP_INI_SCAN_DIR": ["{data}", "{config}", "{run}"]]
    /// Display names leave room for the series and a ` (2)` within an instance name's 64 characters.
    static let maximumDisplayNameLength = 48
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

        guard ServiceInstance.isValidName(recipe.displayName), recipe.displayName.count <= maximumDisplayNameLength else {
            throw fail("the display name \"\(Messages.printable(recipe.displayName) ?? "")\" must be 1 to "
                       + "\(maximumDisplayNameLength) printable characters without \"/\"")
        }
        guard ServiceInstance.isValidID(recipe.kind) else {
            throw fail("the kind \"\(recipe.kind)\" must be lowercase letters and digits joined by single dashes, and not \"bin\"")
        }
        for (field, value) in [("series", recipe.series), ("version", recipe.version)] where !isSafeName(value) {
            throw fail("the \(field) \"\(value)\" must be lowercase letters, digits, dots and dashes, without \"..\"")
        }

        guard recipe.notes.count <= 4, recipe.notes.allSatisfy({
            (1...120).contains($0.count) && Messages.displayName($0, limit: 120) == $0
        }) else {
            throw fail("a note must be 1 to 120 printable characters, and there may be at most 4")
        }
        guard recipe.logHints.count <= 4, recipe.logHints.allSatisfy({ hint in
            [hint.contains, hint.hint].allSatisfy { (1...200).contains($0.count) && Messages.displayName($0, limit: 200) == $0 }
        }) else {
            throw fail("a log hint's text and sentence must be 1 to 200 printable characters, and there may be at most 4")
        }
        if let minimum = recipe.minimumMacOS, ServiceManager.versionNumbers(minimum) == nil {
            throw fail("minimumMacOS \"\(minimum)\" must be a macOS version such as 15.0")
        }

        // Programs.
        for name in recipe.actions.keys.sorted() where !RecipeAction.names.contains(name) {
            throw fail("the action \"\(name)\" is not one Paddock knows")
        }
        let actions = recipe.actions.sorted { $0.key < $1.key }.map(\.value)
        let commands = [recipe.start] + recipe.initialise + recipe.afterReady + actions.map(\.command)
            + [recipe.ready.command].compactMap { $0 }
        for command in commands where !runsFromBinariesOrPHP(command.executable) {
            throw fail("\(command.executable) must be a program under {bin}/ or exactly {php}")
        }
        if recipe.start.stdin != nil || recipe.ready.command?.stdin != nil {
            throw fail("only initialise and afterReady steps may have stdin, not the start or readiness command")
        }
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
                if let roots = folderListVariables[name], !value.split(separator: ":", omittingEmptySubsequences: false)
                    .allSatisfy({ isRootedPath(String($0), roots: roots, restRequired: false) }) {
                    throw fail("every \(name) entry must be \(roots.joined(separator: ", ")), or a literal path under one")
                }
            }
        }

        // Where it writes.
        if let socket = recipe.socket, !isSocketPath(socket) {
            throw fail("the socket \(socket) must be {run}/ followed by one file name, literal but for {port.<name>}")
        }
        for file in recipe.configFiles where !isRootedPath(file.path, roots: ["{config}"], restRequired: true) {
            throw fail("the config file \(file.path) must be {config}/ followed by a literal path")
        }
        for file in recipe.lockFiles where !isLockFilePath(file) {
            throw fail("the lock file \(file) must be {data}/ or {run}/ followed by a literal path, literal but for "
                       + "{port.<name>} in its file name")
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
        if (recipe.readyTimeoutSeconds ?? 1) <= 0 || (recipe.initialiseTimeoutSeconds ?? 1) <= 0
            || actions.contains(where: { ($0.timeoutSeconds ?? 1) <= 0 }) {
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

        // Secrets: named once each, a sensible size.
        guard recipe.secrets.count <= 4 else { throw fail("a recipe may declare at most 4 secrets") }
        var secretNames: Set<String> = []
        for secret in recipe.secrets {
            guard secret.name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
                  secret.name.count <= 32, secretNames.insert(secret.name).inserted else {
                throw fail("the secret \"\(secret.name)\" must be unique, lowercase letters, digits and underscores")
            }
            guard (16...64).contains(secret.bytes) else {
                throw fail("the secret \(secret.name) must be 16 to 64 random bytes")
            }
        }
        let secrets = Set(secretNames.map { "secret.\($0)" })
        /// The first placeholder of `template` that isn't in `allowed`, as the problem it is.
        func check(_ template: String, allowed: Set<String>, actionParameters: Set<String> = [],
                   action: String? = nil) throws {
            for placeholder in ServiceTemplate.placeholders(in: template) where !allowed.contains(placeholder) {
                if secrets.contains(placeholder) {
                    throw fail("{\(placeholder)} may only be in a command's environment or the .env lines, where "
                               + "ps can't show it")
                }
                if let action, actionParameters.contains(placeholder) {
                    throw fail("{\(placeholder)} may only be an argument of \(action), never its program, environment "
                               + "or input")
                }
                throw fail("{\(placeholder)} is not a placeholder Paddock knows")
            }
        }

        // Placeholders. Secrets only in an environment and the .env lines.
        let known = knownPlaceholders.union(recipe.ports.map { "port.\($0.name)" })
        let withSecrets = known.union(secrets)
        var templates = [recipe.socket, recipe.openURL].compactMap { $0 } + recipe.lockFiles
        var secretTemplates = recipe.env
        if recipe.ready.command == nil { templates.append(recipe.ready.template) }
        // (Actions below: their arguments may also use their parameters.)
        for command in [recipe.start] + recipe.initialise + recipe.afterReady + [recipe.ready.command].compactMap({ $0 }) {
            templates += [command.executable] + command.arguments.flatMap(\.templates)
            templates += [command.stdin].compactMap { $0 }
            secretTemplates += Array(command.environment.values)
        }
        templates += recipe.configFiles.flatMap { [$0.path, $0.contents] }
        for template in templates { try check(template, allowed: known) }
        for template in secretTemplates { try check(template, allowed: withSecrets) }

        // An action's parameters: declared once each, with a whole-value pattern, and only ever arguments.
        for (name, action) in recipe.actions.sorted(by: { $0.key < $1.key }) {
            var parameters: Set<String> = []
            for parameter in action.parameters {
                guard parameter.name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
                      !known.contains(parameter.name), !parameter.name.hasPrefix("port"),
                      parameters.insert(parameter.name).inserted else {
                    throw fail("the \(name) parameter \"\(parameter.name)\" must be unique, lowercase letters, digits and "
                               + "underscores, and not a name Paddock uses")
                }
                guard parameter.pattern.hasPrefix("^"), parameter.pattern.hasSuffix("$"),
                      (try? NSRegularExpression(pattern: parameter.pattern)) != nil else {
                    throw fail("the pattern of the \(name) parameter \"\(parameter.name)\" must be a regular expression "
                               + "anchored with ^ and $")
                }
            }
            let command = action.command
            for template in [command.executable] + [command.stdin].compactMap({ $0 }) {
                try check(template, allowed: known, actionParameters: parameters, action: name)
            }
            for template in command.environment.values {
                try check(template, allowed: withSecrets, actionParameters: parameters, action: name)
            }
            for template in command.arguments.flatMap(\.templates) + [action.alreadyDone].compactMap({ $0 }) {
                try check(template, allowed: known.union(parameters))
            }
        }
    }

    /// `{data}/` or `{run}/`, literal folders, then a file name that is literal but for `{port.<name>}`.
    static func isLockFilePath(_ value: String) -> Bool {
        guard let root = ["{data}/", "{run}/"].first(where: value.hasPrefix) else { return false }
        let components = value.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.last else { return false }
        let folders = components.dropLast()
        return folders.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && ServiceTemplate.placeholders(in: $0).isEmpty }
            && !name.isEmpty && name != "." && name != ".."
            && ServiceTemplate.placeholders(in: name).allSatisfy { $0.hasPrefix("port.") }
    }

    /// `{run}/` and one file name: literal text, except `{port.<name>}` (digits once rendered).
    static func isSocketPath(_ value: String) -> Bool {
        guard value.hasPrefix("{run}/") else { return false }
        let name = String(value.dropFirst("{run}/".count))
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && ServiceTemplate.placeholders(in: name).allSatisfy { $0.hasPrefix("port.") }
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
