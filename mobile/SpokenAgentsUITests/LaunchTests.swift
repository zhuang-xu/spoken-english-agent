import XCTest

final class LaunchTests: XCTestCase {
  func testLaunchRequiresAccountBeforePractice() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment = ["UI_TEST_ID": UUID().uuidString, "UI_TEST_SCENARIO": "signedOut"]
    app.launch()
    XCTAssertTrue(app.navigationBars["Spoken Agents"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["accountAvatarButton"].exists)
    app.buttons["accountAvatarButton"].tap()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["signInButton"].exists)
    XCTAssertFalse(app.buttons["Connect"].exists)
  }

  func testHistoryRequiresAnAccountBeforeShowingSavedPractices() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment = ["UI_TEST_ID": UUID().uuidString, "UI_TEST_SCENARIO": "signedOut"]
    app.launch()
    let history = app.tabBars.buttons["History"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.tap()
    XCTAssertTrue(
      app.staticTexts["Sign in to see your conversations and saved coaching."].waitForExistence(
        timeout: 5))
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "practiceRow-Airport practice")
        .firstMatch.exists)
  }
}

// Run explicitly with -only-testing:SpokenAgentsUITests/PhysicalConnectionTests.
// Uses the signed-in development device and the real hosted realtime service.
final class PhysicalConnectionTests: XCTestCase {
  // Explicit assisted test: requires an unlocked, signed-in phone and a speaker.
  func testSpokenTurnAndHostedFeedbackOnPhysicalDevice() throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Requires the physical iPhone and assisted speech input.")
    #else
      continueAfterFailure = false
      let app = XCUIApplication()
      app.launch()
      let online = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "Online"),
        object: app.buttons["accountAvatarButton"])
      XCTAssertEqual(XCTWaiter.wait(for: [online], timeout: 45), .completed)
      app.buttons["startPracticeButton"].tap()
      XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 10))
      app.buttons["connectButton"].tap()
      var ended = false
      // XCTest may abort a failed assertion without running Swift defer.
      // Teardown blocks still run, so failed assisted tests close their session.
      addTeardownBlock {
        if !ended, app.buttons["disconnectButton"].exists, app.buttons["disconnectButton"].isEnabled {
          app.buttons["disconnectButton"].tap()
          if app.buttons["End without feedback"].waitForExistence(timeout: 5) {
            app.buttons["End without feedback"].tap()
          }
        }
      }
      let status = app.staticTexts["callStatus"]
      func awaitStatus(_ title: String, timeout: TimeInterval) -> XCTWaiter.Result {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "label == %@", "Practice status: \(title)"), object: status)], timeout: timeout)
      }
      XCTAssertEqual(awaitStatus("Ready to talk", timeout: 60), .completed)
      app.buttons["startTurnButton"].tap()
      XCTAssertEqual(awaitStatus("Listening to you", timeout: 15), .completed)
      NSLog("PHYSICAL_AUDIO_TEST_RECORDING_READY: speak the agreed test sentence now")
      Thread.sleep(forTimeInterval: 20)
      app.buttons["finishTurnButton"].tap()
      XCTAssertEqual(awaitStatus("Ready to talk", timeout: 40), .completed)
      let transcript = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "usually read a book")).firstMatch
      XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Expected the agreed learner sentence after a real microphone turn")
      NSLog("PHYSICAL_AUDIO_TEST_TRANSCRIPT_RECEIVED")
      app.buttons["disconnectButton"].tap()
      XCTAssertTrue(app.buttons["feedbackButton"].waitForExistence(timeout: 5))
      app.buttons["feedbackButton"].tap()
      XCTAssertEqual(awaitStatus("Conversation complete", timeout: 240), .completed)
      ended = true
      XCTAssertTrue(app.staticTexts["Coaching report saved for offline reading."].waitForExistence(timeout: 10),
                    "Require acknowledged uploads and a saved completed report")
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "Physical spoken-turn and feedback result"
      capture.lifetime = .keepAlways
      add(capture)
      NSLog("PHYSICAL_AUDIO_TEST_FEEDBACK_SAVED")
    #endif
  }

  func testConnectOnPhysicalDevice() throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("This check requires the physical, signed-in iPhone.")
    #else
      continueAfterFailure = false
      let app = XCUIApplication()
      app.launchEnvironment["PHYSICAL_AUDIO_DIAGNOSTICS"] = "1"
      app.launch()
      let start = app.buttons["startPracticeButton"]
      XCTAssertTrue(start.waitForExistence(timeout: 45))
      let online = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "Online"),
        object: app.buttons["accountAvatarButton"])
      XCTAssertEqual(XCTWaiter.wait(for: [online], timeout: 45), .completed,
                     "Wait for hosted account verification before opening setup.")
      start.tap()
      let connect = app.buttons["connectButton"]
      XCTAssertTrue(
        connect.waitForExistence(timeout: 45), "The device must have a cached verified account.")
      XCTAssertTrue(connect.isEnabled)
      connect.tap()
      defer {
        let disconnect = app.buttons["disconnectButton"]
        for _ in 0..<4 {
          if disconnect.exists && disconnect.isHittable { break }
          app.swipeUp()
        }
        if disconnect.exists && disconnect.isEnabled {
          disconnect.tap()
          app.buttons["End without feedback"].tap()
          let idle = NSPredicate(format: "exists == true")
          XCTAssertEqual(
            XCTWaiter.wait(
              for: [
                XCTNSPredicateExpectation(
                  predicate: idle, object: app.buttons["startPracticeButton"])
              ], timeout: 30), .completed)
        } else {
          XCTFail("Could not finish the conversation for cleanup")
        }
      }
      let status = app.staticTexts["callStatus"]
      let connected = NSPredicate(format: "label == %@", "Practice status: Ready to talk")
      let ready = XCTNSPredicateExpectation(predicate: connected, object: status)
      let result = XCTWaiter.wait(for: [ready], timeout: 60)
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "Physical connection result"
      capture.lifetime = .keepAlways
      add(capture)
      XCTAssertEqual(
        result, .completed,
        "Expected Ready to talk; actual status: \(status.exists ? status.label : "missing")")
      XCTAssertTrue(app.buttons["Start speaking"].isEnabled)
      let openingTranscript = app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Agent: ")).firstMatch
      XCTAssertTrue(openingTranscript.waitForExistence(timeout: 20),
                    "Require an agent audio transcript, not only an open data channel")
      // Keep the media path alive for both bounded packet/route snapshots.
      let mediaWindow = expectation(description: "Opening audio diagnostic window")
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) { mediaWindow.fulfill() }
      wait(for: [mediaWindow], timeout: 15)
    #endif
  }
}
