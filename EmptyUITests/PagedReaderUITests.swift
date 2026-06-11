//
//  PagedReaderUITests.swift
//  EmptyUITests
//
//  Functional smoke for 左右翻页: real swipes and edge taps must move
//  through the seeded demo book's pages and across the chapter boundary.
//

import XCTest

final class PagedReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSwipesAndEdgeTapsTurnPagesAcrossChapters() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ScreenshotSeed", "-OpenReader",
            "-reader.pageturn.ios", "paged",
        ]
        app.launch()

        // Page 1 of the seeded book.
        XCTAssertTrue(
            app.staticTexts["思维之书"].firstMatch.waitForExistence(timeout: 12),
            "reader top bar should show the book title"
        )
        XCTAssertTrue(
            app.textViews.containing(
                NSPredicate(format: "value CONTAINS %@", "深读始于空白")
            ).firstMatch.waitForExistence(timeout: 8),
            "first page should render the chapter opening"
        )

        // Swipe through the whole first chapter and across the boundary.
        let chapterTwoMark = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "第 2/2 章"))
            .firstMatch
        var swipes = 0
        while !chapterTwoMark.exists && swipes < 25 {
            app.swipeLeft(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(
            chapterTwoMark.waitForExistence(timeout: 4),
            "swiping past the last page should enter chapter 2 (took \(swipes) swipes)"
        )
        XCTAssertGreaterThan(
            swipes, 2,
            "the long demo chapter should paginate into several pages"
        )
        XCTAssertTrue(
            app.textViews.containing(
                NSPredicate(format: "value CONTAINS %@", "第二章自此开始")
            ).firstMatch.waitForExistence(timeout: 6),
            "chapter 2's first page should render after the boundary"
        )

        // Edge taps: left edge goes back into chapter 1.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        let chapterOneMark = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "第 1/2 章"))
            .firstMatch
        XCTAssertTrue(
            chapterOneMark.waitForExistence(timeout: 6),
            "left-edge tap on chapter 2's first page should land back in chapter 1"
        )

        // Right-edge tap advances again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(
            chapterTwoMark.waitForExistence(timeout: 6),
            "right-edge tap on the last page should re-enter chapter 2"
        )
    }
}
