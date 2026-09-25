import XCTest

/// Walks through the app the way a person would — a link arrives, it is analysed, downloaded,
/// and shows up in the queue and history — and keeps a screenshot of every screen.
///
/// It downloads a real YouTube video, so it only runs when `YTDLPGUI_LIVE_TESTS=1` is set for the
/// test runner (`TEST_RUNNER_YTDLPGUI_LIVE_TESTS=1 xcodebuild test …`).
final class DownloadFlowUITests: XCTestCase {

    /// "Me at the zoo" — 19 seconds, and yt-dlp's own test fixture.
    private static let videoLink = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YTDLPGUI_LIVE_TESTS"] == "1",
            "Set YTDLPGUI_LIVE_TESTS=1 to run the UI walkthrough; it downloads from YouTube."
        )
        continueAfterFailure = false
    }

    @MainActor
    func testLinkToFinishedDownload() throws {
        let app = XCUIApplication()
        app.launch()
        snapshot(app, "01 Download — empty")

        // A ytdlpgui:// link fills in the Download screen and analyses the link.
        var components = URLComponents(string: "ytdlpgui://download")!
        components.queryItems = [URLQueryItem(name: "url", value: Self.videoLink)]
        app.open(components.url!)

        let title = app.staticTexts["Me at the zoo"]
        XCTAssertTrue(title.waitForExistence(timeout: 90), "Analysis didn't show the video's title")
        snapshot(app, "02 Download — analysed")

        // Advanced Options is opened before scrolling: once scrolled, the row can sit under the
        // floating Download bar, and a tap there would start the download instead.
        let advanced = app.buttons["Advanced Options"]
        let downloadBar = app.buttons["startDownloadButton"]
        scroll(app, until: advanced, isAbove: downloadBar)
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced Options"].waitForExistence(timeout: 5))
        snapshot(app, "03 Advanced options")
        app.swipeUp()
        snapshot(app, "04 Advanced options, scrolled")
        app.navigationBars["Advanced Options"].buttons.element(boundBy: 0).tap()

        snapshot(app, "05 Download — analysed, scrolled")

        let download = app.buttons["startDownloadButton"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertTrue(download.isEnabled)
        download.tap()
        answerNotificationPrompt()

        // Queueing switches to the Queue tab, where the item runs to completion.
        let completed = app.staticTexts["Completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 120), "The download didn't complete")
        snapshot(app, "06 Queue — completed")

        app.staticTexts["Me at the zoo"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Me at the zoo"].waitForExistence(timeout: 5), "The item details didn't open")
        snapshot(app, "07 Queue — item details")
        app.swipeUp()
        snapshot(app, "08 Queue — item details, log")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5), "History didn't open")
        XCTAssertTrue(app.staticTexts["Me at the zoo"].waitForExistence(timeout: 10), "The download isn't in History")
        snapshot(app, "09 History")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings didn't open")
        snapshot(app, "10 Settings")
        app.swipeUp()
        snapshot(app, "11 Settings, scrolled")
        app.swipeUp()
        snapshot(app, "12 Settings, bottom")
    }

    /// Scrolls until `element` is on screen and clear of the floating bar, which covers the
    /// bottom of the list; a tap on anything underneath it would hit the bar instead.
    @MainActor
    private func scroll(_ app: XCUIApplication, until element: XCUIElement, isAbove bar: XCUIElement) {
        for _ in 0..<8 {
            if element.exists, element.isHittable, element.frame.maxY < bar.frame.minY - 8 {
                return
            }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("\(element) never scrolled clear of the Download bar")
    }

    /// The app asks for notification permission when the first download starts. A system alert
    /// blocks every tap in the app, so it is answered here rather than left to chance.
    @MainActor
    private func answerNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
