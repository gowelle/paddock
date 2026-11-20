import ArgumentParser
import PaddockCore

struct Paddock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paddock",
        abstract: "Control Paddock from the command line."
    )

    func run() throws {
        print(Self.helpMessage())
    }
}

Paddock.main()
