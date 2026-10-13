import XCTest

final class PracticeJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private var testID: String!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app = XCUIApplication()
    testID = UUID().uuidString
  }

  override func tearDown() {
    if let app {
      if (testRun?.failureCount ?? 0) > 0 {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      app.terminate()
    }
    super.tearDown()
  }

  private func launch(_ scenario: String = "ready") {
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment = ["UI_TEST_ID": testID, "UI_TEST_SCENARIO": scenario]
    app.launch()
    XCTAssertTrue(app.navigationBars["Spoken Agents"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["startPracticeButton"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["accountAvatarButton"].exists)
  }

  private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<6 {
      if element.exists && element.isHittable { return }
      if element.exists && element.frame.minY < 0 { app.swipeDown() } else { app.swipeUp() }
    }
    for _ in 0..<6 {
      if element.exists && element.isHittable { return }
      app.swipeDown()
    }
    XCTAssertTrue(element.exists && element.isHittable, file: file, line: line)
  }

  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    _ = element.waitForExistence(timeout: 2)
    reveal(element, file: file, line: line)
    element.tap()
  }

  private func text(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
    let element = app.staticTexts[label]
    _ = element.waitForExistence(timeout: 3)
    reveal(element, file: file, line: line)
    XCTAssertTrue(element.exists, file: file, line: line)
  }

  private func enabled(
    _ element: XCUIElement, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    reveal(element, file: file, line: line)
    XCTAssertEqual(element.isEnabled, expected, file: file, line: line)
  }

  private func status(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
    reveal(app.staticTexts["callStatus"], file: file, line: line)
    let predicate = NSPredicate(format: "label == %@", "Practice status: \(title)")
    let wait = XCTNSPredicateExpectation(
      predicate: predicate, object: app.staticTexts["callStatus"])
    XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 8), .completed, file: file, line: line)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func openSetup() {
    tap(app.buttons["startPracticeButton"])
    XCTAssertTrue(app.navigationBars["Your session"].waitForExistence(timeout: 5))
  }

  private func connect() {
    if !app.buttons["connectButton"].exists { openSetup() }
    tap(app.buttons["connectButton"])
  }

  private func openAccount() { tap(app.buttons["accountAvatarButton"]) }
  private func closeAccount() { tap(app.buttons["Done"]) }

  private func openPractice(_ title: String) {
    if app.buttons["closeConversationButton"].exists {
      tap(app.buttons["closeConversationButton"])
    }
    tap(app.tabBars.buttons["History"])
    XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    capture("History")
    tap(app.descendants(matching: .any).matching(identifier: "practiceRow-\(title)").firstMatch)
    XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
  }

  private func recordTurn() {
    connect()
    status("Ready to talk")
    tap(app.buttons["startTurnButton"])
    status("Listening to you")
    tap(app.buttons["finishTurnButton"])
    status("Ready to talk")
  }

  func testSignInUnlocksPracticeAndEmptyHistory() {
    launch("signedOut")
    XCTAssertFalse(app.buttons["connectButton"].exists)
    openAccount()
    tap(app.buttons["signInButton"])
    closeAccount()
    XCTAssertTrue(app.buttons["startPracticeButton"].exists)
    tap(app.tabBars.buttons["History"])
    text("No past practices")
    XCTAssertFalse(app.staticTexts["Bob private practice"].exists)
  }

  func testSignInFailureShowsErrorAndAllowsRetry() {
    launch("signInFailure")
    openAccount()
    tap(app.buttons["signInButton"])
    text("API account verification failed (HTTP 401).")
    enabled(app.buttons["signInButton"], true)
    XCTAssertFalse(app.buttons["connectButton"].exists)
    closeAccount()
    XCTAssertTrue(app.tabBars.buttons["History"].exists)
  }

  func testSignOutHidesPracticeAndHistory() {
    launch("history")
    openAccount()
    tap(app.buttons["Sign out"])
    XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["connectButton"].exists)
    closeAccount()
    tap(app.tabBars.buttons["History"])
    XCTAssertFalse(app.staticTexts["Airport practice"].exists)
    text("Sign in to see your conversations and saved coaching.")
  }

  func testInvalidGoalDisablesConnectAndCorrectionEnablesIt() {
    launch()
    openSetup()
    let field = app.textFields["goalField"]
    tap(field)
    let value = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + "\n")
    enabled(app.buttons["connectButton"], false)
    text("Speaking goal must be 2–500 characters.")
    tap(field)
    field.typeText("Airport speaking\n")
    enabled(app.buttons["connectButton"], true)
  }

  func testConnectionFailureCanBeRetried() {
    launch("connectionRetry")
    connect()
    status("Let’s try again")
    enabled(app.buttons["connectButton"], true)
    connect()
    status("Ready to talk")
    enabled(app.buttons["startTurnButton"], true)
  }

  func testMicrophoneDenialShowsRecoveryMessage() {
    launch("permissionDenied")
    connect()
    status("Let’s try again")
    text("Allow microphone access in Settings to practice speaking.")
    XCTAssertFalse(app.buttons["startTurnButton"].exists)
    enabled(app.buttons["connectButton"], true)
  }

  func testRecordingControlsAndTranscript() {
    launch()
    XCTAssertFalse(app.buttons["startTurnButton"].exists)
    XCTAssertFalse(app.buttons["finishTurnButton"].exists)
    connect()
    status("Ready to talk")
    XCTAssertFalse(app.buttons["connectButton"].exists)
    tap(app.buttons["startTurnButton"])
    status("Listening to you")
    XCTAssertFalse(app.buttons["startTurnButton"].exists)
    enabled(app.buttons["finishTurnButton"], true)
    tap(app.buttons["finishTurnButton"])
    status("Ready to talk")
    XCTAssertFalse(app.buttons["finishTurnButton"].exists)
    text("You: I would like a ticket.")
    text("Agent: Where would you like to go?")
  }

  func testBackgroundingStopsActiveRecording() {
    launch()
    connect()
    status("Ready to talk")
    tap(app.buttons["startTurnButton"])
    status("Listening to you")
    XCUIDevice.shared.press(.home)
    app.activate()
    status("Let’s try again")
    text("Practice stopped in the background.")
    enabled(app.buttons["connectButton"], true)
    XCTAssertFalse(app.buttons["startTurnButton"].exists)
  }

  func testEndingWithoutFeedbackReturnsHome() {
    launch()
    connect()
    status("Ready to talk")
    tap(app.buttons["disconnectButton"])
    tap(app.buttons["End without feedback"])
    XCTAssertTrue(app.buttons["startPracticeButton"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["callStatus"].exists)
  }

  func testRejectedRecordingShowsFailureInsteadOfEndlessPending() {
    launch("rejectedAudio")
    recordTurn()
    tap(app.buttons["disconnectButton"])
    tap(app.buttons["feedbackButton"])
    status("Conversation complete")
    tap(app.buttons["viewFeedbackButton"])
    openPractice("Everyday conversation")
    text("1 recordings could not be saved")
    enabled(app.buttons["retryFeedbackButton"], false)
    XCTAssertFalse(app.staticTexts["1 upload items pending"].exists)
    XCTAssertFalse(app.staticTexts["You communicated clearly."].exists)
  }

  func testEndPracticeSavesFeedbackAndConversation() {
    launch()
    recordTurn()
    tap(app.buttons["disconnectButton"])
    tap(app.buttons["feedbackButton"])
    status("Conversation complete")
    tap(app.buttons["viewFeedbackButton"])
    XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    openPractice("Everyday conversation")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I would like a ticket."))
        .firstMatch.exists)
    text("You communicated clearly.")
    enabled(app.buttons["refreshReportButton"], true)
  }

  func testCachedReportSurvivesOfflineRelaunch() {
    launch("history")
    openPractice("Airport practice")
    text("You communicated clearly.")
    app.terminate()
    launch("offline")
    openAccount()
    text("Offline. Saved history is available.")
    closeAccount()
    XCTAssertFalse(app.buttons["connectButton"].exists)
    openPractice("Airport practice")
    text("You communicated clearly.")
    enabled(app.buttons["refreshReportButton"], false)
    text("Pronunciation: Not assessed")
    text("Spoken fluency: Not assessed")
  }

  func testIncompletePracticeRetrySavesFeedback() {
    launch("incomplete")
    openPractice("Pending practice")
    tap(app.buttons["retryFeedbackButton"])
    text("Coaching report saved for offline reading.")
    text("You communicated clearly.")
    XCTAssertFalse(app.buttons["retryFeedbackButton"].exists)
  }

  func testFailedEvaluationCanBeRetriedFromHistory() {
    launch("evaluationFailed")
    openPractice("Pending practice")
    tap(app.buttons["retryFeedbackButton"])
    text("You communicated clearly.")
    XCTAssertFalse(app.buttons["retryFeedbackButton"].exists)
  }

  func testProcessingFeedbackRemainsAvailableForLaterRetry() {
    launch("processing")
    openPractice("Pending practice")
    tap(app.buttons["retryFeedbackButton"])
    text("Feedback is processing. Open History to check again.")
    enabled(app.buttons["retryFeedbackButton"], true)
    XCTAssertFalse(app.staticTexts["You communicated clearly."].exists)
  }

  func testRefreshFailurePreservesVisibleReport() {
    launch("refreshFailure")
    openPractice("Airport practice")
    tap(app.buttons["refreshReportButton"])
    text("Could not refresh. Your saved report is still available.")
    text("You communicated clearly.")
  }

  func testDeleteCancellationAndConfirmationPersistAfterRelaunch() {
    launch("history")
    openPractice("Airport practice")
    tap(app.buttons["deletePracticeButton"])
    XCTAssertTrue(
      app.buttons.matching(identifier: "confirmDeletePracticeButton").firstMatch.waitForExistence(
        timeout: 3))
    if app.buttons["Cancel"].exists {
      app.buttons["Cancel"].tap()
    } else {
      // Newer iOS versions present a popover that dismisses with an outside tap.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.25)).tap()
    }
    XCTAssertFalse(
      app.buttons.matching(identifier: "confirmDeletePracticeButton").firstMatch.exists)
    XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 3))
    tap(app.buttons["deletePracticeButton"])
    tap(app.buttons.matching(identifier: "confirmDeletePracticeButton").firstMatch)
    text("No past practices")
    app.terminate()
    launch("history")
    tap(app.tabBars.buttons["History"])
    text("No past practices")
  }

  func testSwitchingAccountsShowsOnlyNewOwnersHistory() {
    launch("accountSwitch")
    openPractice("Airport practice")
    tap(app.navigationBars["Practice"].buttons.firstMatch)
    tap(app.tabBars.buttons["Home"])
    openAccount()
    tap(app.buttons["Sign out"])
    tap(app.buttons["signInButton"])
    closeAccount()
    XCTAssertTrue(app.buttons["startPracticeButton"].exists)
    tap(app.tabBars.buttons["History"])
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "practiceRow-Bob private practice")
        .firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "practiceRow-Airport practice")
        .firstMatch.exists)
    tap(
      app.descendants(matching: .any).matching(identifier: "practiceRow-Bob private practice")
        .firstMatch)
    XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
  }

  func testDiagnosticsCanPrepareAndRefreshExport() {
    launch("signedOut")
    openAccount()
    tap(app.buttons["Diagnostics"])
    XCTAssertTrue(app.buttons["Share diagnostic log"].waitForExistence(timeout: 5))
    tap(app.buttons["Refresh diagnostic log"])
    XCTAssertTrue(app.buttons["Share diagnostic log"].exists)
    XCTAssertFalse(app.staticTexts["Could not prepare the log. Try again."].exists)
  }
  func testStartPresentsSetupAndCancelDoesNotStartConversation() {
    launch()
    capture("Home")
    XCTAssertFalse(app.staticTexts["callStatus"].exists)
    openSetup()
    capture("Session setup")
    XCTAssertEqual(app.textFields["goalField"].value as? String, "Everyday conversation")
    XCTAssertFalse(app.staticTexts["callStatus"].exists)
    tap(app.buttons["cancelSetupButton"])
    XCTAssertTrue(app.buttons["startPracticeButton"].exists)
    XCTAssertFalse(app.buttons["connectButton"].exists)
    XCTAssertFalse(app.staticTexts["callStatus"].exists)
  }

  func testTravelScenarioPrefillsSetupBeforeConversation() {
    launch()
    tap(app.buttons["scenario-travel"])
    XCTAssertTrue(app.navigationBars["Your session"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields["goalField"].value as? String, "Travel conversation")
    XCTAssertEqual(
      app.textFields["topicField"].value as? String, "Airports, hotels, and getting around")
    tap(app.buttons["connectButton"])
    XCTAssertTrue(app.navigationBars["Conversation"].waitForExistence(timeout: 5))
    status("Ready to talk")
    capture("Conversation")
    XCTAssertFalse(app.tabBars.buttons["Home"].isHittable)
    XCTAssertFalse(app.textFields["goalField"].exists)
  }

  func testHistoryTabIsSeparateAndSignedOutAvatarOpensAccount() {
    launch("signedOut")
    tap(app.tabBars.buttons["History"])
    text("Sign in to see your conversations and saved coaching.")
    openAccount()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    capture("Account")
    XCTAssertTrue(app.buttons["signInButton"].exists)
  }

  func testClosingActiveConversationRequiresAChoiceAndCanBeCancelled() {
    launch()
    connect()
    status("Ready to talk")
    tap(app.buttons["closeConversationButton"])
    XCTAssertTrue(app.buttons["End without feedback"].waitForExistence(timeout: 3))
    if app.buttons["Cancel"].exists {
      tap(app.buttons["Cancel"])
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.25)).tap()
    }
    status("Ready to talk")
    tap(app.buttons["closeConversationButton"])
    tap(app.buttons["End without feedback"])
    XCTAssertTrue(app.buttons["startPracticeButton"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["callStatus"].exists)
  }

}
