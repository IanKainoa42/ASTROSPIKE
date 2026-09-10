import XCTest

final class ASTROSPIKEUITests: XCTestCase {
    @MainActor
    func testLaunchShowsMainModesInLandscape() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--skip-onboarding")
        app.launch()
        XCTAssertTrue(app.buttons["SOLO FLIGHT, ROOKIE • PILOT • ACE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["QUICK MATCH, AUTOMATIC ONLINE DUEL"].exists)
        XCTAssertTrue(app.buttons["LOBBY, WHO'S ONLINE • LIVE DUELS • BRACKETS"].exists)
        XCTAssertTrue(app.buttons["INVITE"].exists)
        XCTAssertTrue(app.frame.width > app.frame.height)
    }

    @MainActor
    func testTutorialAndSettingsEntryPoints() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--skip-onboarding")
        app.launch()

        app.buttons["HOW TO FLY"].tap()
        XCTAssertTrue(app.staticTexts["STEER"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons["SETTINGS"].tap()
        XCTAssertTrue(app.switches["Large controls"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Swap controls for left-handed play"].exists)
        let bounceIncrement = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@",
                "Bounces per hit:",
                "Increment"
            )
        ).firstMatch
        XCTAssertTrue(bounceIncrement.exists)
        let settingsForm = app.collectionViews.firstMatch
        XCTAssertTrue(settingsForm.exists)
        settingsForm.swipeUp()
        let flightTuning = app.buttons["Flight Tuning"]
        XCTAssertTrue(flightTuning.waitForExistence(timeout: 3))
        flightTuning.tap()
        XCTAssertTrue(app.sliders["Gravity"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders["Thrust"].exists)
        XCTAssertTrue(app.sliders["Rotation"].exists)
        app.swipeUp()
        XCTAssertTrue(app.sliders["Ball gravity"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders["Drop height"].exists)
        XCTAssertTrue(app.sliders["Drop speed"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Reset Defaults"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSoloMatchAndPauseFlow() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--skip-onboarding")
        app.launch()
        app.buttons["SOLO FLIGHT, ROOKIE • PILOT • ACE"].tap()
        XCTAssertTrue(app.buttons["ROOKIE, Patient learner"].waitForExistence(timeout: 3))
        app.buttons["ROOKIE, Patient learner"].tap()
        XCTAssertTrue(app.buttons["Pause match"].waitForExistence(timeout: 5))
        let torqueControl = app.buttons["Rotational torque"]
        let thrustControl = app.buttons["Thrust"]
        XCTAssertFalse(torqueControl.exists)
        XCTAssertTrue(thrustControl.exists)
        let rotateLeft = app.buttons["Rotate left"]
        let rotateRight = app.buttons["Rotate right"]
        XCTAssertTrue(rotateLeft.exists)
        XCTAssertTrue(rotateRight.exists)
        XCTAssertGreaterThanOrEqual(rotateLeft.frame.width, 96)
        XCTAssertGreaterThanOrEqual(rotateLeft.frame.height, 96)
        XCTAssertGreaterThanOrEqual(rotateRight.frame.width, 96)
        XCTAssertGreaterThanOrEqual(rotateRight.frame.height, 96)
        XCTAssertGreaterThanOrEqual(thrustControl.frame.width, 112)
        XCTAssertGreaterThanOrEqual(thrustControl.frame.height, 96)
        XCTAssertTrue(app.staticTexts["Your side: Cyan"].exists)

        app.buttons["Pause match"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        app.buttons["Resume"].tap()
        XCTAssertFalse(app.buttons["Resume"].exists)
    }

    @MainActor
    func testGameCenterDiagnosticsPanelSurfacesValidationFields() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--online-diagnostics-preview"]
        app.launchArguments.append("--skip-onboarding")
        app.launch()

        XCTAssertTrue(app.buttons["game-center-diagnostics-toggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["diagnostics-player-value"].exists)
        app.buttons["game-center-diagnostics-toggle"].tap()
        XCTAssertEqual(app.staticTexts["diagnostics-player-value"].label, "GC TEST PILOT")
        XCTAssertEqual(app.staticTexts["diagnostics-side-value"].label, "CYAN")
        XCTAssertEqual(app.staticTexts["diagnostics-authority-value"].label, "HOST")
        XCTAssertEqual(app.staticTexts["diagnostics-ping-value"].label, "42 MS")
        XCTAssertEqual(app.staticTexts["diagnostics-link-value"].label, "RECONNECTING")
        XCTAssertEqual(app.staticTexts["diagnostics-match-value"].label, "READY")
        XCTAssertEqual(app.staticTexts["diagnostics-reconnect-value"].label, "7 S")
        XCTAssertEqual(app.staticTexts["diagnostics-event-value"].label, "10:46:09 INVITE → WINGMAN: NO ANSWER")
        XCTAssertFalse(app.staticTexts["GAME CENTER OFFLINE"].exists)
    }

    @MainActor
    func testOnlineModeDoesNotOfferLocalOnlyPauseOrSoloTuning() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--online-diagnostics-preview"]
        app.launchArguments.append("--skip-onboarding")
        app.launch()

        XCTAssertTrue(app.buttons["Leave online match"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pause match"].exists)
        XCTAssertFalse(app.buttons["Flight Tuning"].exists)
        app.buttons["Leave online match"].tap()
        XCTAssertTrue(app.staticTexts["Leave Match?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Leave Match"].exists)
    }
}

extension ASTROSPIKEUITests {
    /// Settings → Arrange pads: a drag moves the pad and the offset persists.
    func testArrangePadsDragMovesThrustPad() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--warmup", "--skip-onboarding", "-arrangePads", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let thrust = app.descendants(matching: .any)["thrust-control"]
        if !thrust.waitForExistence(timeout: 8) {
            let tree = app.debugDescription
            XCTFail("no thrust-control; tree: \(tree.prefix(3000))")
            return
        }
        XCTAssertTrue(app.staticTexts["DRAG THE PADS"].exists, "arrange mode not on")
        let before = thrust.frame
        let start = thrust.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -160, dy: -80))
        start.press(forDuration: 0.2, thenDragTo: end)
        let moved = NSPredicate { _, _ in abs(thrust.frame.midX - before.midX) > 40 }
        let expectation = XCTNSPredicateExpectation(predicate: moved, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 3), .completed,
                       "thrust pad did not move: \(before) → \(thrust.frame)")
        let after = thrust.frame
        app.terminate()
        app.launch()
        let again = app.descendants(matching: .any)["thrust-control"]
        XCTAssertTrue(again.waitForExistence(timeout: 8))
        XCTAssertEqual(again.frame.midX, after.midX, accuracy: 2, "offset did not persist: \(after) vs \(again.frame)")
        XCTAssertEqual(again.frame.midY, after.midY, accuracy: 2)
    }
}

extension ASTROSPIKEUITests {
    /// A pad shoved at the corner stops at the corner. The layout ships to
    /// everyone, and a pad flung past the glass would be gone for good --
    /// there is no per-pad undo, only the global reset.
    func testArrangePadsClampToTheScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--warmup", "--skip-onboarding", "-arrangePads", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let thrust = app.descendants(matching: .any)["thrust-control"]
        XCTAssertTrue(thrust.waitForExistence(timeout: 8))

        let start = thrust.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let corner = app.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.999))
        start.press(forDuration: 0.2, thenDragTo: corner)

        let landed = NSPredicate { _, _ in thrust.frame.maxX > 0 }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 2)

        let window = app.frame
        let pad = thrust.frame
        XCTAssertLessThanOrEqual(pad.maxX, window.maxX + 1, "pad ran off the right edge: \(pad) in \(window)")
        XCTAssertLessThanOrEqual(pad.maxY, window.maxY + 1, "pad ran off the bottom: \(pad) in \(window)")
        XCTAssertGreaterThanOrEqual(pad.minX, window.minX - 1, "pad ran off the left edge: \(pad)")
        XCTAssertGreaterThanOrEqual(pad.minY, window.minY - 1, "pad ran off the top: \(pad)")
    }

    /// DONE leaves arrange mode without a trip through Settings, and RESET
    /// puts the pads back where they were drawn.
    func testDoneChipLeavesArrangeMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--warmup", "--skip-onboarding", "--arrange-pads"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let done = app.buttons["finish-arranging"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "no DONE chip in arrange mode")
        XCTAssertTrue(app.buttons["reset-pads-inline"].exists, "no RESET chip in arrange mode")
        done.tap()
        let gone = NSPredicate { _, _ in !app.buttons["finish-arranging"].exists }
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 3),
            .completed,
            "DONE did not leave arrange mode"
        )
        XCTAssertFalse(app.staticTexts["DRAG THE PADS"].exists)
    }
}
