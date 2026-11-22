import Foundation

/// One line of a dump, with what is nested in it: a value, or an array or object with its members.
public struct DumpNode: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case scalar, string, hash
        /// `…3`: members left out.
        case ellipsis
    }

    public let id: Int
    public let kind: Kind
    /// The key (when it is a member) and the value's first line: `"total" => 59.0`, `#lines: array:2 [`.
    public var head: String
    /// The further lines of a string that has several.
    public var body: [String]
    public var children: [DumpNode]
    /// The closing bracket, on a line of its own, when there are members.
    public var tail: String?

    public init(id: Int, kind: Kind, head: String, body: [String] = [], children: [DumpNode] = [], tail: String? = nil) {
        self.id = id
        self.kind = kind
        self.head = head
        self.body = body
        self.children = children
        self.tail = tail
    }

    /// Whether there is anything to fold away.
    public var isFoldable: Bool { !children.isEmpty || !body.isEmpty }

    /// The lines as VarDumper's own text output writes them, indented two spaces a level.
    func lines(depth: Int = 0, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        lines.append(pad + head)
        for line in body { lines.append(pad + line) }
        for child in children { child.lines(depth: depth + 1, into: &lines) }
        if let tail { lines.append(pad + tail) }
    }
}

/// One `dump()` (or one value of a `dd()`): what was dumped, where and during what.
public struct Dump: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: Date?
    /// `GET https://shop.test/orders/1042`, or `artisan queue:work` for a command; nil when it wasn't said.
    public let origin: String?
    /// The file the dump is in, and its line.
    public let file: String?
    public let line: Int?
    public let root: DumpNode

    public init(id: Int, time: Date?, origin: String?, file: String?, line: Int?, root: DumpNode) {
        self.id = id
        self.time = time
        self.origin = origin
        self.file = file
        self.line = line
        self.root = root
    }

    /// `OrderController.php:42`.
    public var source: String? {
        guard let file else { return nil }
        let name = (file as NSString).lastPathComponent
        return line.map { "\(name):\($0)" } ?? name
    }

    /// The whole dump as text, as VarDumper prints it in a terminal.
    public var text: String {
        var lines: [String] = []
        root.lines(into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum DumpError: Error, Equatable {
    /// The payload is not what VarDumper's dump server client sends.
    case notADump
    /// More than Paddock shows of one dump.
    case tooLarge
}

/// Reads what Symfony VarDumper's dump server client sends (`base64(serialize([Data, context]))`) into a
/// `Dump`. A port of VarDumper's own walk over its data (`Data::dump`) and of the way its text dumper writes
/// each value, so a dump reads here as it does in a terminal. Nothing in the payload is run.
public struct DumpDecoder {
    /// The most lines kept of one dump.
    public static let nodeLimit = 50_000

    private static let typeRef = 1, typeString = 2, typeArray = 3, typeObject = 4, typeResource = 5, typeScalar = 6
    private static let hashAssoc = 1, hashIndexed = 2, hashObject = 4, hashResource = 5

    private var table: [Int: [PHPValue.Entry]] = [:]
    private var maxDepth = 20
    private var maxItemsPerDepth = -1
    private var useRefHandles = -1
    private var refs: [Int: Int] = [:]
    private var refCount = 0
    private var nextNode = 0
    private var collapseNextHash = false

    /// One line as it arrived (base64, without its line end).
    public static func decode(line: Data, id: Int) throws -> Dump {
        guard let raw = Data(base64Encoded: line, options: .ignoreUnknownCharacters), !raw.isEmpty else {
            throw DumpError.notADump
        }
        let value: PHPValue
        do {
            value = try PHPSerialized.parse(raw)
        } catch PHPSerializedError.tooLarge {
            throw DumpError.tooLarge
        } catch {
            throw DumpError.notADump
        }
        return try decode(value, id: id)
    }

    static func decode(_ payload: PHPValue, id: Int) throws -> Dump {
        guard case .array(let pair) = payload, pair.count == 2,
              case .object(let className, let properties) = pair[0].value, className.hasSuffix("\\Data") else {
            throw DumpError.notADump
        }
        var decoder = DumpDecoder()
        // The Data object's properties are private: their names are `\0<class>\0<name>`.
        var fields: [String: PHPValue] = [:]
        for property in properties {
            let name = property.key.text
            fields[name.split(separator: "\0").last.map(String.init) ?? name] = property.value
        }
        guard case .array(let positions)? = fields["data"] else { throw DumpError.notADump }
        for position in positions {
            guard case .int(let index) = position.key, case .array(let items) = position.value else { continue }
            decoder.table[index] = items
        }
        decoder.maxDepth = fields["maxDepth"]?.intValue ?? 20
        decoder.maxItemsPerDepth = fields["maxItemsPerDepth"]?.intValue ?? -1
        decoder.useRefHandles = fields["useRefHandles"]?.intValue ?? -1
        let position = fields["position"]?.intValue ?? 0
        let key: PHPKey
        switch fields["key"] {
        case .string(let bytes)?: key = .string(bytes)
        case .int(let number)?: key = .int(number)
        default: key = .int(0)
        }
        guard let item = decoder.table[position]?.first(where: { $0.key == key })?.value else { throw DumpError.notADump }

        var cursor = Cursor()
        var root = try decoder.item(&cursor, item)
        if let label = fields["context"]?["label"]?.stringValue, !label.isEmpty {
            root.head = Self.styled(label, binary: false) + " " + root.head
        }

        let context = pair[1].value
        var time: Date?
        if case .double(let seconds)? = context["timestamp"] { time = Date(timeIntervalSince1970: seconds) }
        if case .int(let seconds)? = context["timestamp"] { time = Date(timeIntervalSince1970: TimeInterval(seconds)) }
        var origin: String?
        if let request = context["request"], let uri = request["uri"]?.stringValue {
            origin = [request["method"]?.stringValue, uri].compactMap { $0 }.joined(separator: " ")
        } else if let command = context["cli"]?["command_line"]?.stringValue {
            origin = command
        }
        let source = context["source"]
        return Dump(id: id, time: time, origin: origin.flatMap { Messages.printable($0, limit: 300) },
                    file: source?["file"]?.stringValue.flatMap { Messages.printable($0, limit: 1024) },
                    line: source?["line"]?.intValue, root: root)
    }

    // MARK: - The walk (Data::dump)

    private struct Cursor {
        var depth = 0
        var hashType = 0
        var hashKey: PHPKey?
        var hashKeyIsBinary = false
        var refIndex = 0
        var softRefTo = 0, softRefHandle = 0, softRefCount = 0
        var hardRefTo = 0, hardRefHandle = 0, hardRefCount = 0
        var attr: [String: PHPValue] = [:]
        var stop = false
        var skipChildren = false
    }

    /// A VarDumper stub: how an array, object, string or reference is recorded.
    private struct Stub {
        var type = DumpDecoder.typeRef
        var classValue: PHPValue = .string(Data())
        var value: PHPValue = .null
        var cut = 0, handle = 0, refCount = 0, position = 0
        var attr: [String: PHPValue] = [:]

        init() {}

        init(properties: [PHPValue.Entry]) {
            for property in properties {
                let name = property.key.text.split(separator: "\0").last.map(String.init) ?? property.key.text
                switch name {
                case "type": type = property.value.intValue ?? type
                case "class": classValue = property.value
                case "value": value = property.value
                case "cut": cut = property.value.intValue ?? 0
                case "handle": handle = property.value.intValue ?? 0
                case "refCount": refCount = property.value.intValue ?? 0
                case "position": position = property.value.intValue ?? 0
                case "attr":
                    for entry in property.value.entries ?? [] { attr[entry.key.text] = entry.value }
                default: break
                }
            }
        }
    }

    private mutating func node(_ kind: DumpNode.Kind, _ head: String, body: [String] = [], children: [DumpNode] = [],
                               tail: String? = nil) throws -> DumpNode {
        nextNode += 1
        guard nextNode <= Self.nodeLimit else { throw DumpError.tooLarge }
        return DumpNode(id: nextNode, kind: kind, head: head, body: body, children: children, tail: tail)
    }

    /// An array as VarDumper records one in place: `[<kind> => <position>]`, with `[0 => <cut>]` when cut.
    private func arrayStub(_ entries: [PHPValue.Entry]) -> Stub {
        var stub = Stub()
        stub.type = Self.typeArray
        if let last = entries.last {
            switch last.key {
            case .int(let number): stub.classValue = .int(number)
            case .string(let bytes): stub.classValue = .string(bytes)
            }
            stub.position = last.value.intValue ?? 0
        }
        if let cut = entries.first(where: { $0.key == .int(0) })?.value.intValue { stub.cut = cut }
        stub.value = .int(stub.cut + (stub.position != 0 ? (table[stub.position]?.count ?? 0) : 0))
        return stub
    }

    private static func typeName(_ value: PHPValue) -> String {
        switch value {
        case .null: return "NULL"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "double"
        case .string, .enumCase: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func isTruthy(_ value: PHPValue) -> Bool {
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .string(let bytes): return !bytes.isEmpty && bytes != Data("0".utf8)
        case .array(let entries): return !entries.isEmpty
        case .object, .enumCase: return true
        }
    }

    private mutating func item(_ cursor: inout Cursor, _ original: PHPValue) throws -> DumpNode {
        cursor.refIndex = 0
        cursor.softRefTo = 0; cursor.softRefHandle = 0; cursor.softRefCount = 0
        cursor.hardRefTo = 0; cursor.hardRefHandle = 0; cursor.hardRefCount = 0
        var firstSeen = true
        var type = ""
        var plain = original
        var stub: Stub?

        switch original {
        case .object(_, let properties):
            let found = Stub(properties: properties)
            if found.type == Self.typeRef {
                if found.handle != 0 {
                    let key = found.handle - (Int.max >> 1)
                    if let seen = refs[key] {
                        firstSeen = false
                        cursor.hardRefTo = seen
                    } else {
                        refCount += 1
                        refs[key] = refCount
                        cursor.refIndex = refCount
                        cursor.hardRefTo = refCount
                    }
                    cursor.hardRefHandle = useRefHandles & found.handle
                    cursor.hardRefCount = found.handle > 0 ? found.refCount : 0
                }
                cursor.attr = found.attr
                type = Self.isTruthy(found.classValue) ? Self.plainText(found.classValue) : Self.typeName(found.value)
                switch found.value {
                case .array(let entries) where !entries.isEmpty:
                    stub = arrayStub(entries)
                case .object(_, let inner):
                    stub = Stub(properties: inner)
                default:
                    plain = found.value
                    stub = nil
                }
            } else {
                stub = found
            }
        case .array(let entries) where !entries.isEmpty:
            cursor.attr = [:]
            type = "array"
            stub = arrayStub(entries)
        default:
            cursor.attr = [:]
            type = Self.typeName(original)
        }

        guard let stub else {
            if type == "array" {
                return try node(.hash, key(&cursor) + "[]")
            }
            if case .string(let bytes) = plain, type == "string" {
                return try string(&cursor, bytes, binary: false, cut: 0)
            }
            return try scalar(&cursor, type, plain)
        }

        if stub.refCount != 0 {
            if let seen = refs[stub.handle] {
                firstSeen = false
                cursor.softRefTo = seen
            } else {
                if cursor.refIndex == 0 {
                    refCount += 1
                    cursor.refIndex = refCount
                }
                refs[stub.handle] = cursor.refIndex
                cursor.softRefTo = cursor.refIndex
            }
        }
        cursor.softRefHandle = useRefHandles & stub.handle
        cursor.softRefCount = stub.refCount
        cursor.attr = stub.attr
        var cut = stub.cut
        var children: [PHPValue.Entry] = []
        if stub.position != 0, firstSeen {
            children = table[stub.position] ?? []
            if cursor.stop {
                if cut >= 0 { cut += children.count }
                children = []
            }
        }

        switch stub.type {
        case Self.typeString:
            let bytes: Data
            if case .string(let data) = stub.value { bytes = data } else { bytes = Data(Self.plainText(stub.value).utf8) }
            return try string(&cursor, bytes, binary: stub.classValue.intValue == 1, cut: cut)

        case Self.typeArray, Self.typeObject, Self.typeResource:
            var hashType = stub.type
            var className = stub.classValue
            if stub.type == Self.typeArray {
                hashType = stub.classValue.intValue ?? Self.hashIndexed
                className = stub.value
            }
            var withChildren = !children.isEmpty && cursor.depth != maxDepth && maxItemsPerDepth != 0
            var head = key(&cursor)
            let attr = cursor.attr
            let cutHash = attr["cut_hash"].map(Self.isTruthy) ?? false
            if collapseNextHash {
                cursor.skipChildren = true
                collapseNextHash = false
            }
            let hasChild = withChildren && !cursor.skipChildren
            let name = Self.plainText(className)
            var prefix: String
            switch hashType {
            case Self.hashObject:
                prefix = Self.isTruthy(className) && name != "stdClass"
                    ? Self.styled(name, binary: false) + (cutHash ? "" : " {") : "{"
            case Self.hashResource:
                prefix = Self.styled(name + " resource", binary: false) + (hasChild ? " {" : " ")
            default:
                prefix = Self.isTruthy(className) ? "array:" + name + " [" : "["
            }
            if (cursor.softRefCount != 0 || cursor.softRefHandle > 0), !cutHash {
                prefix += (hashType == Self.hashResource ? "@" : "#")
                    + String(cursor.softRefHandle > 0 ? cursor.softRefHandle : cursor.softRefTo)
            } else if cursor.hardRefTo != 0, cursor.refIndex == 0, Self.isTruthy(className) {
                prefix += "&\(cursor.hardRefTo)"
            } else if !hasChild, hashType == Self.hashResource {
                prefix.removeLast()
            }
            head += prefix

            var nodes: [DumpNode] = []
            if withChildren {
                if cursor.skipChildren {
                    withChildren = false
                    cut = -1
                } else {
                    cut = try self.children(&cursor, children, cut: cut, hashType: hashType,
                                            keys: !isNull(className), into: &nodes)
                }
            } else if !children.isEmpty, cut >= 0 {
                cut += children.count
            }
            cursor.skipChildren = false

            var tail: String?
            if !cutHash {
                let close = hashType == Self.hashObject ? "}" : (hashType != Self.hashResource ? "]" : (withChildren ? "}" : ""))
                if cut != 0 {
                    let ellipsis = " \u{2026}" + (cut > 0 ? String(cut) : "")
                    if withChildren { nodes.append(try node(.ellipsis, ellipsis)) } else { head += ellipsis }
                }
                if withChildren { tail = close } else { head += close }
            }
            return try node(.hash, head, children: nodes, tail: tail)

        case Self.typeScalar:
            return try scalar(&cursor, "default", stub.attr["value"] ?? .null)

        default:
            throw DumpError.notADump
        }
    }

    private func isNull(_ value: PHPValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    /// The members of an array or object. Returns how many were left out in the end.
    private mutating func children(_ parent: inout Cursor, _ children: [PHPValue.Entry], cut: Int, hashType: Int,
                                   keys: Bool, into nodes: inout [DumpNode]) throws -> Int {
        var cursor = parent
        cursor.depth += 1
        cursor.hashType = hashType
        var index = 0
        for child in children {
            if case .string(let bytes) = child.key {
                cursor.hashKeyIsBinary = !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil
            } else {
                cursor.hashKeyIsBinary = false
            }
            cursor.hashKey = keys ? child.key : nil
            nodes.append(try item(&cursor, child.value))
            index += 1
            if index == maxItemsPerDepth || cursor.stop {
                parent.stop = true
                return cut >= 0 ? cut + children.count - index : cut
            }
        }
        return cut
    }

    // MARK: - Writing a value (CliDumper)

    /// The key in front of a member, as VarDumper writes it for the kind of thing it is in.
    private mutating func key(_ cursor: inout Cursor) -> String {
        guard let hashKey = cursor.hashKey else { return "" }
        var line = ""
        let binary = cursor.hashKeyIsBinary
        let mark = binary ? "b" : ""
        let text = hashKey.text

        switch cursor.hashType {
        case Self.hashObject, Self.hashResource:
            var bytes: [UInt8]
            switch hashKey {
            case .int(let number): bytes = Array(String(number).utf8)
            case .string(let data): bytes = [UInt8](data)
            }
            if cursor.hashType == Self.hashResource { bytes = [0, UInt8(ascii: "~"), 0] + bytes }
            if bytes.first != 0 {
                line += "+" + mark + Self.styled(text, binary: binary) + ": "
            } else if let second = bytes.dropFirst().firstIndex(of: 0), second > 1 {
                let kind = PHPValue.text(Data(bytes[1..<second]))
                let name = PHPValue.text(Data(bytes[(second + 1)...]))
                var separator = ": "
                var prefix = mark
                switch kind.first {
                case "+":
                    line += "+" + mark + "\"" + Self.styled(name, binary: binary) + "\": "
                    return line + hardReference(cursor)
                case "~":
                    // `~collapse=1&separator=%20`: how a caster asks for a member to be shown.
                    for pair in kind.dropFirst().split(separator: "&") {
                        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        let value = parts.count > 1
                            ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1]))
                            : ""
                        if parts[0] == "separator" { separator = value }
                        if parts[0] == "collapse", !value.isEmpty, value != "0" { collapseNextHash = true }
                    }
                case "*":
                    prefix = "#" + mark
                default:
                    prefix = "-" + mark
                }
                line += prefix + Self.styled(name, binary: binary) + separator
            } else {
                line += "-" + mark + "\"" + Self.styled(text, binary: binary) + "\": "
            }
        default:
            if case .int(let number) = hashKey {
                line += "\(number) => "
            } else {
                line += mark + "\"" + Self.styled(text, binary: binary) + "\" => "
            }
        }
        return line + hardReference(cursor)
    }

    /// `&1 `: the value is a PHP reference shared with another shown.
    private func hardReference(_ cursor: Cursor) -> String {
        cursor.hardRefTo != 0 ? "&" + (cursor.hardRefCount != 0 ? String(cursor.hardRefTo) : "") + " " : ""
    }

    private mutating func scalar(_ cursor: inout Cursor, _ type: String, _ value: PHPValue) throws -> DumpNode {
        let head = key(&cursor)
        collapseNextHash = false
        let text: String
        switch type {
        case "default", "label": text = Self.plainText(value)
        case "integer": text = Self.plainText(value)
        case "double":
            if case .double(let number) = value { text = Self.float(number) } else { text = Self.plainText(value) }
        case "NULL": text = "null"
        case "boolean": text = Self.isTruthy(value) ? "true" : "false"
        default: text = type
        }
        return try node(.scalar, head + Self.styled(text, binary: false))
    }

    private mutating func string(_ cursor: inout Cursor, _ bytes: Data, binary: Bool, cut: Int) throws -> DumpNode {
        var head = key(&cursor)
        collapseNextHash = false
        let text = PHPValue.text(bytes)
        if text.isEmpty {
            return try node(.string, head + "\"\"" + (cut != 0 ? "\u{2026}\(cut)" : ""))
        }
        var parts = binary && text.contains("\0") ? [text] : text.components(separatedBy: "\n")
        if parts.count == 2, parts[1].isEmpty {
            parts = [parts[0] + "\n"]
        }
        let last = parts.count - 1
        if binary { head += "b" }
        let ending = cut < 0 ? "\u{2026}" : (cut != 0 ? "\u{2026}\(cut)" : "")
        guard last > 0 else {
            return try node(.string, head + "\"" + Self.styled(parts[0], binary: binary) + "\"" + ending)
        }
        // Several lines: `"""`, each line (its line end shown as \n), then `"""`; indented one level more
        // when it is a member.
        let pad = cursor.depth > 0 ? "  " : ""
        var body: [String] = []
        for (index, part) in parts.enumerated() {
            if index < last {
                body.append(pad + Self.styled(part + "\n", binary: binary))
            } else if !part.isEmpty {
                body.append(pad + Self.styled(part, binary: binary))
            }
        }
        body.append(pad + "\"\"\"" + ending)
        return try node(.string, head + "\"\"\"", body: body)
    }

    // MARK: - Text

    /// A value as PHP would print it.
    private static func plainText(_ value: PHPValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag ? "1" : ""
        case .int(let number): return String(number)
        case .double(let number): return float(number, pointZero: false)
        case .string(let bytes): return PHPValue.text(bytes)
        case .enumCase(let name): return name
        case .array: return "Array"
        case .object(let className, _): return className
        }
    }

    /// A float as PHP's default `precision` (14) writes it, and as VarDumper then shows it (`2.0`, `1.0E+100`).
    static func float(_ number: Double, pointZero: Bool = true) -> String {
        if number.isNaN { return "NAN" }
        if number.isInfinite { return number < 0 ? "-INF" : "INF" }
        var text = String(format: "%.14G", number)
        if let e = text.firstIndex(of: "E") {
            var mantissa = String(text[..<e])
            var exponent = String(text[text.index(after: e)...])
            let sign = exponent.first == "-" ? "-" : "+"
            exponent = String(exponent.drop { $0 == "+" || $0 == "-" }.drop { $0 == "0" })
            if exponent.isEmpty { exponent = "0" }
            if !mantissa.contains(".") { mantissa += ".0" }
            text = mantissa + "E" + sign + exponent
        }
        if pointZero, !text.contains(".") { text += ".0" }
        return text
    }

    private static let invisible: Set<UInt32> = {
        var set: Set<UInt32> = [0x00A0, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x202F, 0x205F,
                                0x3000, 0x2800, 0x3164, 0xFEFF, 0xFFA0, 0x1D159]
        for range in [0x0080...0x009F, 0x2000...0x200F, 0x2060...0x2064, 0x206A...0x206F, 0x1D173...0x1D17A] {
            for scalar in range { set.insert(UInt32(scalar)) }
        }
        return set
    }()

    /// Text as VarDumper shows it: control characters as `\t`, `\n`, `\x01`…, and (unless it is binary)
    /// characters that can't be seen as `\u{…}`.
    static func styled(_ text: String, binary: Bool) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (!binary && invisible.contains($0.value)) })
        else { return text }
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0B: out += "\\v"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x1B: out += "\\e"
            case 0x00...0x1F, 0x7F: out += String(format: "\\x%02X", scalar.value)
            default:
                if !binary, invisible.contains(scalar.value) {
                    out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
