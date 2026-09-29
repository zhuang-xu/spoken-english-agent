import XCTest

final class LaunchTests: XCTestCase {
    func testLaunchShowsPracticeSetup() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spoken Agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect"].exists)
        XCTAssertTrue(app.staticTexts["Ready to connect"].exists)
    }

    func testHistoryOpensFromPracticeScreen() {
        let app = XCUIApplication()
        app.launch()
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    }
}
