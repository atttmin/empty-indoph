//
//  ScreenshotTests.swift
//  EmptyUITests
//
//  Captures real product screenshots. Defaults to a temp folder because the
//  UI-test runner is sandboxed on macOS; override with SCREENSHOT_OUTPUT_DIR.
//

import XCTest

final class ScreenshotTests: XCTestCase {
    private let demoBookTitle = "思维之书"
    private let demoHighlightText = "深读始于空白"

    private let outputDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["SCREENSHOT_OUTPUT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appending(path: "EmptyScreenshots", directoryHint: .isDirectory)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    @MainActor
    func testCaptureMacLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ScreenshotSeed"]
        app.launch()

        let libraryTitle = app.staticTexts["书库"]
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 8))

        let seededBook = app.staticTexts[demoBookTitle].firstMatch
        XCTAssertTrue(seededBook.waitForExistence(timeout: 8))

        try saveScreenshot(named: "mac-library", from: app)
    }

    @MainActor
    func testCaptureMacReader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ScreenshotSeed", "-OpenReader"]
        app.launch()

        let readerChrome = app.buttons["‹ 书库"]
        XCTAssertTrue(readerChrome.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts[demoBookTitle].firstMatch.waitForExistence(timeout: 4))

        sleep(2)
        try saveScreenshot(named: "mac-reader", from: app)
    }

    @MainActor
    func testCaptureMacHighlights() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ScreenshotSeed", "-ScreenshotSeedHighlight", "-OpenReader"]
        app.launch()

        let openHighlights = app.buttons["reader.highlights"]
        XCTAssertTrue(openHighlights.waitForExistence(timeout: 12))
        openHighlights.tap()

        assertHighlightSheet(in: app)
        try saveScreenshot(named: "mac-highlights", from: app)

        let jump = app.buttons["跳回原文"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 8))
        jump.tap()
        XCTAssertTrue(app.buttons["‹ 书库"].waitForExistence(timeout: 8))
    }

    #if os(iOS)
    @MainActor
    func testCaptureIOSLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ScreenshotSeed"]
        app.launch()

        let libraryTitle = app.staticTexts["书库"]
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[demoBookTitle].firstMatch.waitForExistence(timeout: 8))

        sleep(1)
        try saveScreenshot(named: "ios-library", from: app)
    }

    @MainActor
    func testCaptureIOSReading() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ScreenshotSeed"]
        app.launch()

        let seededBook = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", demoBookTitle)).firstMatch
        XCTAssertTrue(seededBook.waitForExistence(timeout: 12))
        seededBook.tap()

        let readerBack = app.buttons["‹"]
        XCTAssertTrue(readerBack.waitForExistence(timeout: 12))

        sleep(2)
        try saveScreenshot(named: "ios-reading", from: app)
    }

    @MainActor
    func testCaptureIOSHighlights() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ScreenshotSeed", "-ScreenshotSeedHighlight"]
        app.launch()

        let seededBook = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", demoBookTitle)).firstMatch
        XCTAssertTrue(seededBook.waitForExistence(timeout: 12))
        seededBook.tap()

        let overflow = app.buttons["reader.overflow"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 12))
        overflow.tap()

        let menuHighlight = app.buttons["高亮"].firstMatch
        XCTAssertTrue(menuHighlight.waitForExistence(timeout: 8))
        menuHighlight.tap()

        assertHighlightSheet(in: app)
        try saveScreenshot(named: "ios-highlights", from: app)

        let jump = app.buttons["跳回原文"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 8))
        jump.tap()
        XCTAssertTrue(app.buttons["‹"].waitForExistence(timeout: 8))
    }
    #endif

    private func assertHighlightSheet(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["高亮 · 朱批"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["跳回原文"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["编辑批注"].firstMatch.waitForExistence(timeout: 8))
    }

    private func saveScreenshot(named name: String, from app: XCUIApplication) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let path = outputDirectory.appending(path: "\(name).png")
        #if os(macOS)
        guard let tiff = screenshot.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode screenshot \(name)")
            return
        }
        try data.write(to: path)
        #else
        let image = screenshot.image
        guard let data = image.pngData() else {
            XCTFail("Could not encode screenshot \(name)")
            return
        }
        try data.write(to: path)
        #endif
    }
}