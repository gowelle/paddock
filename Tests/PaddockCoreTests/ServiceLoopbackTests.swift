import XCTest
@testable import PaddockCore

/// Every service listens on this Mac only. Renders everything each bundled recipe hands its program (the
/// start command, its arguments and environment, every initialise step and stdin, the readiness probe
/// and every config file) with sample values, and fails on a wildcard listen address. Recipes added later are covered
/// without touching this test.
final class ServiceLoopbackTests: XCTestCase {
    private func sampleContext(_ recipe: ServiceRecipe) -> ServiceTemplateContext {
        var ports: [String: Int] = [:]
        for (index, port) in recipe.ports.enumerated() { ports[port.name] = 40000 + index }
        var context = ServiceTemplateContext(
            bin: "/h/services/bin/\(recipe.kind)/\(recipe.version)", data: "/h/services/x/data",
            config: "/h/services/x/config", run: "/h/run/svc/x", log: "/h/log/service-x.log",
            name: recipe.displayName, id: recipe.kind, ports: ports, socket: "/h/run/svc/x/x.sock",
            php: "/h/bin/php", resources: "/r")
        context.secrets = Dictionary(uniqueKeysWithValues: recipe.secrets.map { ($0.name, "sampleSecretValue_0123456789") })
        return context
    }

    /// Every rendered string a recipe passes to its program.
    private func renderedTexts(_ recipe: ServiceRecipe) throws -> [String] {
        let context = sampleContext(recipe)
        var texts: [String] = []
        for command in [recipe.start] + recipe.initialise {
            let rendered = try ServiceTemplate.render(command, context: context)
            texts.append(rendered.executable)
            texts += rendered.arguments
            texts += rendered.environment.map { "\($0.key)=\($0.value)" }
            if let stdin = rendered.stdin { texts += stdin.components(separatedBy: .newlines) }
        }
        texts.append(try ServiceTemplate.render(recipe.ready.template, context: context))
        for file in recipe.configFiles {
            texts += try ServiceTemplate.renderFile(file.contents, context: context).components(separatedBy: .newlines)
        }
        return texts
    }

    func testNoBundledRecipeListensOnAWildcardAddress() throws {
        let catalog = try ServiceCatalog.bundled()
        XCTAssertFalse(catalog.recipes.isEmpty)
        for recipe in catalog.recipes {
            let texts = try renderedTexts(recipe)
            for text in texts {
                XCTAssertNil(ServiceLoopback.wildcard(in: text), "\(recipe.kind) \(recipe.version): \(text)")
            }
            // Something in the command names loopback when the recipe has TCP ports.
            if !recipe.ports.isEmpty {
                XCTAssertTrue(texts.contains { $0.contains("127.0.0.1") }, "\(recipe.kind) binds 127.0.0.1")
            }
        }
    }

    func testDetectorCatchesWildcards() {
        for text in ["0.0.0.0:8025", "--listen=0.0.0.0", "[::]:1025", "::", "--bind ::", "listen_addresses='*'",
                     "listen_addresses = '*'", "*:8080", "--host *", "--host=*", "bind 0.0.0.0 ::1", "--addr :8080",
                     "-h *"] {
            XCTAssertNotNil(ServiceLoopback.wildcard(in: text), text)
        }
        for text in ["127.0.0.1:8025", "[::1]:1025", "::1", "--host 127.0.0.1", "listen_addresses='127.0.0.1'",
                     "MAIL_PORT=1025", "/h/services/x/data", "*.log", "a*b", "http://127.0.0.1:8025/readyz",
                     "--allowed-hosts 127.0.0.1:1,localhost:1"] {
            XCTAssertNil(ServiceLoopback.wildcard(in: text), text)
        }
    }
}
