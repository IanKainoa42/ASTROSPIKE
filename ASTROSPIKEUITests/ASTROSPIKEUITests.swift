import XCTest

final class ASTROSPIKEUITests: XCTestCase {
    @MainActor
    func testLaunchShowsMainModesInLandscape() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["SOLO FLIGHT, ROOKIE • PILOT • ACE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["QUICK MATCH, AUTOMATIC ONLINE DUEL"].exists)
        XCTAssertTrue(app.buttons["INVITE A FRIEND, GAME CENTER"].exists)
        XCTAssertTrue(app.frame.width > app.frame.height)
    }

    @MainActor
    func testTutorialAndSettingsEntryPoints() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["HOW TO FLY"].tap()
        XCTAssertTrue(app.staticTexts["STEER"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons["SETTINGS"].tap()
        XCTAssertTrue(app.switches["Large controls"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Swap controls for left-handed play"].exists)
        app.buttons["Flight Tuning"].tap()
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
}
