import Foundation
import XCTest
@testable import PaddockCore

final class DatabaseGridWidthsTests: XCTestCase {
    func testEveryColumnStartsAtTheDefaultWidth() {
        let widths = DatabaseGridWidths(columns: 3)
        XCTAssertEqual(widths[0], DatabaseGridWidths.initial)
        XCTAssertEqual(widths[1], DatabaseGridWidths.initial)
        XCTAssertEqual(widths[2], DatabaseGridWidths.initial)
        XCTAssertEqual(widths.total, DatabaseGridWidths.initial * 3)
    }

    func testResizingOneColumnLeavesTheOthersAlone() {
        var widths = DatabaseGridWidths(columns: 3)
        widths.resize(1, to: 300)
        XCTAssertEqual(widths[0], DatabaseGridWidths.initial)
        XCTAssertEqual(widths[1], 300)
        XCTAssertEqual(widths[2], DatabaseGridWidths.initial)
    }

    func testAColumnCannotBeNarrowerThanTheMinimumOrWiderThanTheMaximum() {
        var widths = DatabaseGridWidths(columns: 2)
        widths.resize(0, to: 10)
        XCTAssertEqual(widths[0], DatabaseGridWidths.minimum)
        widths.resize(1, to: 100_000)
        XCTAssertEqual(widths[1], DatabaseGridWidths.maximum)
    }

    func testResizingAColumnThatIsNotThereChangesNothing() {
        var widths = DatabaseGridWidths(columns: 1)
        widths.resize(4, to: 300)
        XCTAssertEqual(widths[0], DatabaseGridWidths.initial)
        XCTAssertEqual(widths.total, DatabaseGridWidths.initial)
    }

    func testNoColumnsMeansNoWidths() {
        XCTAssertEqual(DatabaseGridWidths(columns: 0).total, 0)
    }
}
