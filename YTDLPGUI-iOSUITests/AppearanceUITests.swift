import XCTest

/// Offline coverage of the redesigned controls and navigation; no downloads or library edits.
final class AppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDarkNavigationAndFormatSelection() {
        let app = launch()
        let video = app.buttons["format-video"]
        let audio = app.buttons["format-audio"]
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        let originallyVideo = video.value as? String == "Selected"
        snapshot(app, "01 Dark Download")
        reveal(audio, in: app)
        audio.tap()
        XCTAssertEqual(audio.value as? String, "Selected")
        XCTAssertTrue(app.buttons["startDownloadButton"].exists)
        XCTAssertFalse(app.buttons["startDownloadButton"].isEnabled)
        snapshot(app, "02 Audio controls")
        video.tap()
        XCTAssertEqual(video.value as? String, "Selected")
        if !originallyVideo { audio.tap() }

        let advanced = app.buttons["Advanced Options"]
        reveal(advanced, in: app)
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced Options"].waitForExistence(timeout: 5))
        snapshot(app, "03 Advanced Options")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        for title in ["Queue", "History", "Settings"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            snapshot(app, "04 \(title)")
        }
    }

    @MainActor
    func testAccessibilityTextCanReachControls() {
        let app = launch(largeText: true)
        XCTAssertTrue(app.buttons["startDownloadButton"].waitForExistence(timeout: 15))
        snapshot(app, "05 Accessibility text — link")
        let video = app.buttons["format-video"]
        let audio = app.buttons["format-audio"]
        reveal(video, in: app)
        XCTAssertTrue(video.isHittable)
        reveal(audio, in: app)
        XCTAssertTrue(audio.isHittable)
        snapshot(app, "06 Accessibility text — formats")
        let advanced = app.buttons["Advanced Options"]
        reveal(advanced, in: app)
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced Options"].waitForExistence(timeout: 5))
        snapshot(app, "07 Accessibility text — advanced")
    }

    @MainActor
    func testLightAppearanceRemainsReadable() {
        let app = launch(appearance: "light")
        XCTAssertTrue(app.buttons["format-video"].waitForExistence(timeout: 15))
        snapshot(app, "08 Light Download")
    }

    @MainActor
    private func launch(appearance: String = "dark", largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // Argument-domain overrides leave the user's stored preferences intact.
        app.launchArguments = [
            "-appearanceMode", appearance,
            "-autoAnalyzePastedURLs", "NO",
            "-suggestClipboardLinks", "NO",
            "-showCommandPreview", "NO",
        ]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let bar = app.buttons["startDownloadButton"]
        for _ in 0..<10 {
            if element.exists, element.isHittable,
               element.frame.maxY < bar.frame.minY - 8 { return }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Control never scrolled clear of the Download button: \(element)")
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
