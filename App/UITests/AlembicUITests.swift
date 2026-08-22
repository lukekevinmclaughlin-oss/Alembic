import XCTest

final class AlembicUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFreemiumSubscriptionAndFreePipelinePaths() throws {
        let app = XCUIApplication()
        app.launch()

        let tryPremium = app.buttons["Try Premium"]
        XCTAssertTrue(tryPremium.waitForExistence(timeout: 8))
        tryPremium.tap()

        XCTAssertTrue(app.staticTexts["Alembic Pro"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Annual"].exists)
        XCTAssertTrue(app.staticTexts["Monthly"].exists)
        XCTAssertTrue(app.buttons["Start Free Trial"].exists)
        XCTAssertTrue(app.buttons["Restore Purchases"].exists)
        XCTAssertTrue(app.buttons["Manage Subscription"].exists)
        XCTAssertTrue(app.buttons["Continue Free"].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "Continue Free"))
            .element(boundBy: 1).tap()

        let sample = app.buttons["Try with sample data"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()

        let run = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "run")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 6))
        run.tap()
        XCTAssertTrue(app.navigationBars["Report"].waitForExistence(timeout: 15))
    }
}
