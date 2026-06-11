//
//  ScreenshotTests.swift
//  EmptyUITests
//
//  Captures real product screenshots into docs/screenshots for README / website.
//

import XCTest

final class ScreenshotTests: XCTestCase {
    private let outputDirectory = "/Users/davirian/dev/Empty/docs/screenshots"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    @MainActor
    func testCaptureMacLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        let libraryTitle = app.staticTexts["书库"]
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 8))

        try saveScreenshot(named: "mac-library", from: app)
    }

    @MainActor
    func testCaptureMacReader() throws {
        let app = XCUIApplication()
        app.launch()

        let continueButton = app.buttons["继续阅读 →"]
        if continueButton.waitForExistence(timeout: 8) {
            continueButton.tap()
        } else {
            let recentBook = app.staticTexts["The Book of Elon"].firstMatch
            if recentBook.waitForExistence(timeout: 3) {
                recentBook.tap()
            }
        }

        let readerChrome = app.staticTexts["‹ 书库"]
        XCTAssertTrue(readerChrome.waitForExistence(timeout: 12))

        sleep(2)
        try saveScreenshot(named: "mac-reader", from: app)
    }

    #if os(iOS)
    @MainActor
    func testCaptureIOSLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        let libraryTab = app.tabBars.buttons["书库"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 8))

        sleep(1)
        try saveScreenshot(named: "ios-library", from: app)
    }

    @MainActor
    func testCaptureIOSReading() throws {
        let app = XCUIApplication()
        app.launch()

        let readTab = app.tabBars.buttons["阅读"]
        if readTab.waitForExistence(timeout: 5) {
            readTab.tap()
        }

        sleep(2)
        try saveScreenshot(named: "ios-reading", from: app)
    }
    #endif

    private func saveScreenshot(named name: String, from app: XCUIApplication) throws {
        let screenshot = app.screenshot()
        let path = "\(outputDirectory)/\(name).png"
        #if os(macOS)
        guard let tiff = screenshot.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode screenshot \(name)")
            return
        }
        try data.write(to: URL(fileURLWithPath: path))
        #else
        let image = screenshot.image
        guard let data = image.pngData() else {
            XCTFail("Could not encode screenshot \(name)")
            return
        }
        try data.write(to: URL(fileURLWithPath: path))
        #endif
    }
}