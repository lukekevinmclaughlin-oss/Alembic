import XCTest
@testable import AlembicEngine

final class ColumnProfileTests: XCTestCase {

    func testNumericColumnProfile() {
        let ds = Dataset.fresh(columns: ["score", "label"], rows: [
            [.int(5), .string("a")],
            [.int(3), .string("b")],
            [.int(9), .string("a")],
            [.null, .string("a")]
        ])
        let p = ColumnProfiler.profile(ds, column: "score")!
        XCTAssertEqual(p.sampleCount, 4)
        XCTAssertEqual(p.nonNullCount, 3)
        XCTAssertEqual(p.nullFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(p.dominantType, "int")
        XCTAssertEqual(p.uniqueCount, 3)
        XCTAssertEqual(p.numericMin, 3)
        XCTAssertEqual(p.numericMax, 9)
        XCTAssertEqual(p.numericMean!, 17.0 / 3.0, accuracy: 0.001)
        XCTAssertTrue(p.isNumeric)
        XCTAssertFalse(p.isText)
    }

    func testTextColumnProfileTokensAndTopValues() {
        let ds = Dataset.fresh(columns: ["label"], rows: [
            [.string("apple")], [.string("apple")], [.string("apple")],
            [.string("banana")], [.string("cherry")]
        ])
        let p = ColumnProfiler.profile(ds, column: "label")!
        XCTAssertEqual(p.dominantType, "string")
        XCTAssertTrue(p.isText)
        XCTAssertEqual(p.tokenMin ?? -1, p.tokenMin)      // present
        XCTAssertNotNil(p.tokenMean)
        XCTAssertGreaterThan(p.tokenTotal ?? 0, 0)
        // Top value is "apple" with count 3
        XCTAssertEqual(p.topValues.first?.value, "apple")
        XCTAssertEqual(p.topValues.first?.count, 3)
        XCTAssertEqual(p.uniqueCount, 3)
    }

    func testMissingColumnReturnsNil() {
        let ds = Dataset.fresh(columns: ["a"], rows: [[.int(1)]])
        XCTAssertNil(ColumnProfiler.profile(ds, column: "nope"))
    }

    func testAllNullColumn() {
        let ds = Dataset.fresh(columns: ["x"], rows: [[.null], [.null]])
        let p = ColumnProfiler.profile(ds, column: "x")!
        XCTAssertEqual(p.nullFraction, 1.0)
        XCTAssertEqual(p.nonNullCount, 0)
        XCTAssertFalse(p.isNumeric)
        XCTAssertTrue(p.topValues.isEmpty)
    }
}
