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
        // The one flight preference a pilot keeps: steering feel, per device.
        XCTAssertTrue(app.sliders["Turning sensitivity"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Large controls"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Swap controls for left-handed play"].exists)
        let settingsForm = app.collectionViews.firstMatch
        XCTAssertTrue(settingsForm.exists)
        let bounceIncrement = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@",
                "Bounces per hit:",
                "Increment"
            )
        ).firstMatch
        reveal(bounceIncrement, in: settingsForm)
        // The developer sliders are gone from the shipped app: no Flight
        // Tuning page, and no ball or tractor slider on the Settings form.
        XCTAssertFalse(app.buttons["Flight Tuning"].exists)
        XCTAssertFalse(app.sliders["Ball size"].exists)
        XCTAssertFalse(app.sliders["Pull strength"].exists)
    }

    /// Scroll `element` into reach, one bounded loop per element asserted on --
    /// never one loop for the whole screen. A loop that stops at the first row
    /// is not a loop that reaches the row below it, so every Section added to
    /// Settings would otherwise push the next assertion off the fold and break
    /// a test that has nothing to do with the change. Slow swipes because one
    /// full-velocity `swipeUp` overshoots whole sections.
    ///
    /// Hittable rather than existent on purpose: a row nudged to the very
    /// bottom edge is in the hierarchy while a tap on it lands somewhere else,
    /// which reads as a flake rather than as the layout problem it is.
    @MainActor
    private func reveal(
        _ element: XCUIElement,
        in scroller: XCUIElement,
        nudges: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0 ..< nudges where !element.isHittable {
            scroller.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(
            element.isHittable,
            "\(nudges) nudges never brought \(element) into reach",
            file: file,
            line: line
        )
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
        // Landscape phones get the margin layout: one steering strip, not
        // separate rotate buttons.
        let steering = app.descendants(matching: .any)["steering-control"]
        XCTAssertTrue(steering.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(steering.frame.width, 96)
        XCTAssertGreaterThanOrEqual(steering.frame.height, 96)
        XCTAssertGreaterThanOrEqual(thrustControl.frame.width, 112)
        XCTAssertGreaterThanOrEqual(thrustControl.frame.height, 96)
        XCTAssertTrue(app.staticTexts["Your side: Cyan"].exists)

        app.buttons["Pause match"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Restart Drop"].exists)
        XCTAssertFalse(app.sliders["Gravity"].exists)
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

    @MainActor
    func testHangarShowsPrivacyAndTermsNextToRestore() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--skip-onboarding")
        app.launch()

        app.buttons["hangar"].tap()
        XCTAssertTrue(app.navigationBars["Hangar"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["hull-restore"].waitForExistence(timeout: 3)
                || app.staticTexts["RESTORE PURCHASES"].waitForExistence(timeout: 3),
            "Restore Purchases missing from Hangar"
        )
        XCTAssertTrue(app.buttons["hangar-privacy"].waitForExistence(timeout: 3), "Privacy Policy missing next to Restore")
        XCTAssertTrue(app.buttons["hangar-terms"].exists, "Terms of Use missing next to Restore")
    }

    @MainActor
    func testResultsWinOffersPlayAgainChallengeAndBackToMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--results-win", "--skip-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["YOU WIN"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["PLAY AGAIN"].exists)
        XCTAssertTrue(app.buttons["CHALLENGE PILOT"].exists)
        XCTAssertTrue(app.buttons["BACK TO MENU"].exists)
    }

    @MainActor
    func testResultsLoseRetriesTheSameRival() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--results-lose", "--skip-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["YOU LOSE"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["CHALLENGE PILOT"].exists)
        app.buttons["PLAY AGAIN"].tap()
        XCTAssertTrue(app.buttons["Pause match"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["YOU LOSE"].exists)
    }

    @MainActor
    func testResultsBackToMenuReturnsHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--results-win", "--skip-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["BACK TO MENU"].waitForExistence(timeout: 5))
        app.buttons["BACK TO MENU"].tap()
        XCTAssertTrue(app.buttons["SOLO FLIGHT, ROOKIE • PILOT • ACE"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testResultsChallengeStartsTheNextRival() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--results-win", "--skip-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["CHALLENGE PILOT"].waitForExistence(timeout: 5))
        app.buttons["CHALLENGE PILOT"].tap()
        XCTAssertTrue(app.buttons["Pause match"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["YOU WIN"].exists)
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

        let window = app.frame
        let landed = NSPredicate { _, _ in
            let f = thrust.frame
            return f.maxX <= window.maxX + 1 && f.maxY <= window.maxY + 1
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 3)
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
