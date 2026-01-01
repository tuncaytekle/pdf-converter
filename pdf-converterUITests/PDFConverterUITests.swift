import XCTest

final class PDFConverterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabBarSwitchesBetweenFilesAndTools() throws {
        let app = makeConfiguredApp()
        app.launch()

        let filesTab = app.tabBars.buttons["Files"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        XCTAssertTrue(filesTab.isSelected, "Files tab should be the default selection on launch.")

        let toolsTab = app.tabBars.buttons["Tools"]
        XCTAssertTrue(toolsTab.waitForExistence(timeout: 2))
        toolsTab.tap()

        XCTAssertTrue(toolsTab.isSelected, "Tools tab should become selected after tapping it.")
        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 2), "Tools navigation bar should be visible after switching tabs.")
    }

    @MainActor
    func testCreateButtonOnlyVisibleOnFilesTab() throws {
        let app = makeConfiguredApp()
        app.launch()

        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Floating create button should be visible on the Files tab.")

        let toolsTab = app.tabBars.buttons["Tools"]
        XCTAssertTrue(toolsTab.waitForExistence(timeout: 2))
        toolsTab.tap()

        XCTAssertFalse(createButton.waitForExistence(timeout: 1), "Floating create button should be hidden after leaving the Files tab.")
    }

    private func makeConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedOnboarding", "YES"]
        return app
    }
}
