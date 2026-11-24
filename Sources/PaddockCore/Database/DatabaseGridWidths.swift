import Foundation

/// The Databases grid's column widths: one per column, dragged in the header, kept between a minimum so a
/// column stays legible and a maximum so it does not run away.
public struct DatabaseGridWidths: Equatable, Sendable {
    public static let initial: CGFloat = 168
    public static let minimum: CGFloat = 80
    public static let maximum: CGFloat = 1600

    private var widths: [CGFloat]

    public init(columns: Int) {
        widths = Array(repeating: Self.initial, count: max(0, columns))
    }

    public var total: CGFloat { widths.reduce(0, +) }

    public subscript(column: Int) -> CGFloat {
        widths.indices.contains(column) ? widths[column] : Self.initial
    }

    public mutating func resize(_ column: Int, to width: CGFloat) {
        guard widths.indices.contains(column) else { return }
        widths[column] = min(max(width, Self.minimum), Self.maximum)
    }
}
