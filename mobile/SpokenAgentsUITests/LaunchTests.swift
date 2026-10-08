import XCTest

final class LaunchTests: XCTestCase {
    func testLaunchRequiresAccountBeforePractice() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spoken Agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Account"].exists)
        XCTAssertTrue(app.buttons["signInButton"].exists)
        XCTAssertFalse(app.buttons["Connect"].exists)
    }

    func testHistoryIsHiddenUntilAnAccountIsVerified() {
        let app = XCUIApplication()
        app.launch()
        let history = app.buttons["History"]
        XCTAssertFalse(history.waitForExistence(timeout: 2))
    }
}

// Run explicitly with -only-testing:SpokenAgentsUITests/PhysicalConnectionTests.
// Uses the signed-in development device and the real hosted realtime service.
final class PhysicalConnectionTests: XCTestCase {
    func testConnectOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This check requires the physical, signed-in iPhone.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 45), "The device must have a cached verified account.")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        defer {
            let disconnect = app.buttons["Disconnect"]
            for _ in 0..<4 {
                if disconnect.exists && disconnect.isHittable { break }
                app.swipeUp()
            }
            if disconnect.exists && disconnect.isEnabled {
                disconnect.tap()
                let idle = NSPredicate(format: "label == %@", "Practice status: Ready to connect")
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: idle, object: app.staticTexts["callStatus"])], timeout: 30), .completed)
            } else {
                XCTFail("Could not reach Disconnect for cleanup")
            }
        }
        let status = app.staticTexts["callStatus"]
        let connected = NSPredicate(format: "label == %@", "Practice status: Connected")
        let ready = XCTNSPredicateExpectation(predicate: connected, object: status)
        let result = XCTWaiter.wait(for: [ready], timeout: 60)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Physical connection result"
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertEqual(result, .completed, "Expected Connected; actual status: \(status.exists ? status.label : "missing")")
        XCTAssertTrue(app.buttons["Start speaking"].isEnabled)
        #endif
    }
}
