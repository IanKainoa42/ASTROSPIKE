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
        XCTAssertTrue(torqueControl.exists)
        XCTAssertTrue(thrustControl.exists)
        XCTAssertEqual(torqueControl.frame.width, 92, accuracy: 2)
        XCTAssertEqual(torqueControl.frame.height, 92, accuracy: 2)
        XCTAssertEqual(thrustControl.frame.width, 92, accuracy: 2)
        XCTAssertEqual(thrustControl.frame.height, 92, accuracy: 2)
        XCTAssertFalse(app.buttons["Rotate left"].exists)
        XCTAssertFalse(app.buttons["Rotate right"].exists)
        XCTAssertTrue(app.staticTexts["Your side: Cyan"].exists)

        app.buttons["Pause match"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        app.buttons["Resume"].tap()
        XCTAssertFalse(app.buttons["Resume"].exists)
    }
}
