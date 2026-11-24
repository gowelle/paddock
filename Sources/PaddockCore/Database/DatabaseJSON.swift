import Foundation

/// A JSON object or array held in a text cell: a compact form for the grid's one line, and an indented form for
/// the viewer. A bare number, string or other scalar is text, not a document, and stays in the grid as it is.
public enum DatabaseJSON {
    public struct Document: Equatable, Sendable {
        public let preview: String
        public let pretty: String
    }

    public static func document(_ text: String) -> Document? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any]
        else { return nil }
        // Sorted keys make the same document read the same way every time.
        guard let preview = string(object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let pretty = string(object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return Document(preview: preview, pretty: pretty)
    }

    private static func string(_ object: Any, options: JSONSerialization.WritingOptions) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
