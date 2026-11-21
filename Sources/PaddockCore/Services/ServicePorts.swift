import Foundation

public enum ServicePortError: Error, Equatable {
    /// Neither the preferred port nor any of the `ServicePorts.searchLimit` ports above it is free.
    case noFreePort(name: String, preferred: Int)
}

/// Chooses the ports of a new instance. Nothing is asked: the conventional port if it is free, else the
/// next free one above it.
public enum ServicePorts {
    /// How far above the preferred port Paddock looks.
    public static let searchLimit = 100

    /// Each port of the recipe: the preferred one if it is free and no other instance owns it (`taken`),
    /// else the next such port above it, at most `searchLimit` higher. Ports of one recipe never collide.
    public static func choose(for recipe: ServiceRecipe, taken: Set<Int>, isFree: (Int) -> Bool) throws
        -> [String: Int] {
        var used = taken
        var chosen: [String: Int] = [:]
        for port in recipe.ports {
            guard let found = (port.preferred...(port.preferred + searchLimit)).first(where: {
                $0 <= 65535 && !used.contains($0) && isFree($0)
            }) else {
                throw ServicePortError.noFreePort(name: port.name, preferred: port.preferred)
            }
            chosen[port.name] = found
            used.insert(found)
        }
        return chosen
    }

    /// The recipe with every preferred port moved up by `base` (nil leaves it as it is).
    public static func shifted(_ recipe: ServiceRecipe, base: Int?) -> ServiceRecipe {
        guard let base else { return recipe }
        return recipe.withPorts(recipe.ports.map { RecipePort(name: $0.name, preferred: $0.preferred + base) })
    }

    public static let portBaseVariable = "PADDOCK_SERVICE_PORT_BASE"
    /// Largest base: conventional ports (all below 10000) plus the search stay below 65536.
    static let maximumPortBase = 55000

    /// `PADDOCK_SERVICE_PORT_BASE`, which moves every service's preferred ports into a high range so tests
    /// never touch the conventional ones. Read only in a development home (`PADDOCK_HOME` set); a real home
    /// ignores it.
    public static func portBase(environment: [String: String]) -> Int? {
        guard !SystemIntegration.isEnabled(environment: environment),
              let text = environment[portBaseVariable], let base = Int(text),
              (1024...maximumPortBase).contains(base) else { return nil }
        return base
    }
}
