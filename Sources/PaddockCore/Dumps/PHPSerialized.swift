import Foundation

/// A key of a PHP array or an object's property.
public enum PHPKey: Hashable, Sendable {
    case int(Int)
    case string(Data)

    /// The key as text (a string key that isn't UTF-8 is read as Windows-1252, as VarDumper shows it).
    var text: String {
        switch self {
        case .int(let number): return String(number)
        case .string(let bytes): return PHPValue.text(bytes)
        }
    }
}

/// A value read from PHP's `serialize()` format. Strings stay bytes: PHP's are not always text.
public indirect enum PHPValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(Data)
    case array([Entry])
    /// An object: its class and its properties (a private or protected one's name carries PHP's `\0` marks).
    case object(className: String, properties: [Entry])
    /// An enum case, as `Class:Case`.
    case enumCase(String)

    public struct Entry: Sendable {
        public let key: PHPKey
        public let value: PHPValue
    }

    /// Bytes as text: UTF-8 when they are, else Windows-1252 (then Latin-1, which maps every byte).
    static func text(_ bytes: Data) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    var entries: [Entry]? {
        switch self {
        case .array(let entries): return entries
        case .object(_, let properties): return properties
        default: return nil
        }
    }

    var intValue: Int? {
        if case .int(let number) = self { return number }
        return nil
    }

    var stringValue: String? {
        if case .string(let bytes) = self { return PHPValue.text(bytes) }
        return nil
    }

    /// The value under a string key (of an array, or a public property of an object).
    subscript(name: String) -> PHPValue? {
        let wanted = PHPKey.string(Data(name.utf8))
        return entries?.first { $0.key == wanted }?.value
    }
}

public enum PHPSerializedError: Error, Equatable {
    /// The bytes are not PHP's serialize format, or stop short.
    case malformed(at: Int)
    /// More nesting or more values than Paddock reads from one dump.
    case tooLarge
}

/// Reads PHP's `serialize()` format into values. It builds plain data only: no class is looked up and nothing
/// is run, whatever the bytes say, so it is safe on bytes from anywhere. Bounded in depth and in size.
public struct PHPSerialized {
    /// The deepest nesting read.
    public static let depthLimit = 256
    /// The most values read from one input.
    public static let valueLimit = 2_000_000

    private let bytes: [UInt8]
    private var index = 0
    /// Every value in the order PHP numbered it, for `r:` and `R:` (which name an earlier value by number).
    private var slots: [PHPValue] = []

    public static func parse(_ data: Data) throws -> PHPValue {
        var parser = PHPSerialized(bytes: [UInt8](data))
        let value = try parser.value(depth: 0)
        guard parser.index == parser.bytes.count else { throw PHPSerializedError.malformed(at: parser.index) }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func fail() -> PHPSerializedError { .malformed(at: index) }

    private mutating func expect(_ character: Character) throws {
        guard index < bytes.count, bytes[index] == character.asciiValue else { throw fail() }
        index += 1
    }

    /// The bytes up to (not including) `end`, which is consumed.
    private mutating func token(until end: Character) throws -> String {
        let start = index
        guard let endByte = end.asciiValue else { throw fail() }
        while index < bytes.count, bytes[index] != endByte {
            index += 1
            if index - start > 64 { throw fail() }
        }
        guard index < bytes.count else { throw fail() }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        index += 1
        return text
    }

    private mutating func integer(until end: Character) throws -> Int {
        guard let number = Int(try token(until: end)) else { throw fail() }
        return number
    }

    /// `<length>:"<bytes>"` (the `s:` or the class name of an `O:`), without what follows the closing quote.
    private mutating func quoted() throws -> Data {
        let length = try integer(until: ":")
        try expect("\"")
        guard length >= 0, index + length < bytes.count else { throw fail() }
        let data = Data(bytes[index..<index + length])
        index += length
        try expect("\"")
        return data
    }

    private mutating func reserve() throws -> Int {
        guard slots.count < Self.valueLimit else { throw PHPSerializedError.tooLarge }
        slots.append(.null)
        return slots.count - 1
    }

    private mutating func entries(depth: Int) throws -> [PHPValue.Entry] {
        let count = try integer(until: ":")
        try expect("{")
        guard count >= 0, count <= bytes.count - index else { throw fail() }
        var entries: [PHPValue.Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let key: PHPKey
            guard index + 1 < bytes.count else { throw fail() }
            let kind = bytes[index]
            index += 1
            try expect(":")
            switch kind {
            case UInt8(ascii: "i"):
                key = .int(try integer(until: ";"))
            case UInt8(ascii: "s"):
                key = .string(try quoted())
                try expect(";")
            default:
                throw fail()
            }
            entries.append(.init(key: key, value: try value(depth: depth + 1)))
        }
        try expect("}")
        return entries
    }

    private mutating func value(depth: Int) throws -> PHPValue {
        guard depth <= Self.depthLimit else { throw PHPSerializedError.tooLarge }
        guard index < bytes.count else { throw fail() }
        let kind = bytes[index]
        index += 1
        switch kind {
        case UInt8(ascii: "N"):
            try expect(";")
            return try store(.null)
        case UInt8(ascii: "b"):
            try expect(":")
            return try store(.bool(try integer(until: ";") != 0))
        case UInt8(ascii: "i"):
            try expect(":")
            return try store(.int(try integer(until: ";")))
        case UInt8(ascii: "d"):
            try expect(":")
            let text = try token(until: ";")
            let number: Double
            switch text {
            case "INF": number = .infinity
            case "-INF": number = -.infinity
            case "NAN": number = .nan
            default:
                guard let parsed = Double(text) else { throw fail() }
                number = parsed
            }
            return try store(.double(number))
        case UInt8(ascii: "s"):
            try expect(":")
            let data = try quoted()
            try expect(";")
            return try store(.string(data))
        case UInt8(ascii: "a"):
            try expect(":")
            let slot = try reserve()
            let value = PHPValue.array(try entries(depth: depth))
            slots[slot] = value
            return value
        case UInt8(ascii: "O"):
            try expect(":")
            let name = PHPValue.text(try quoted())
            try expect(":")
            let slot = try reserve()
            let value = PHPValue.object(className: name, properties: try entries(depth: depth))
            slots[slot] = value
            return value
        case UInt8(ascii: "E"):
            try expect(":")
            let name = PHPValue.text(try quoted())
            try expect(";")
            return try store(.enumCase(name))
        case UInt8(ascii: "C"):
            // A class with its own serialized form: its bytes are skipped, the object kept without properties.
            try expect(":")
            let name = PHPValue.text(try quoted())
            try expect(":")
            let length = try integer(until: ":")
            try expect("{")
            guard length >= 0, index + length < bytes.count else { throw fail() }
            index += length
            try expect("}")
            return try store(.object(className: name, properties: []))
        case UInt8(ascii: "r"), UInt8(ascii: "R"):
            // An earlier value again, by its number. `r:` (the same object) takes a number of its own; `R:`
            // (a PHP reference) does not.
            try expect(":")
            let number = try integer(until: ";")
            guard number >= 1, number <= slots.count else { throw fail() }
            let value = slots[number - 1]
            return kind == UInt8(ascii: "r") ? try store(value) : value
        default:
            index -= 1
            throw fail()
        }
    }

    private mutating func store(_ value: PHPValue) throws -> PHPValue {
        slots[try reserve()] = value
        return value
    }
}
