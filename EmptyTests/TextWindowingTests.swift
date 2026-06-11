//
//  TextWindowingTests.swift
//  EmptyTests
//

import Testing
@testable import Empty

struct TextWindowingTests {
    @Test func emptyTextProducesNoWindows() {
        #expect(TextWindowing.windows(for: "", maxCharacters: 100).isEmpty)
        #expect(TextWindowing.windows(for: "  \n\n  ", maxCharacters: 100).isEmpty)
    }

    @Test func shortTextIsOneWindow() {
        let windows = TextWindowing.windows(for: "Hello world.", maxCharacters: 100)
        #expect(windows == ["Hello world."])
    }

    @Test func windowsRespectBudget() {
        let paragraphs = (0..<20).map { "Paragraph \($0) with some content." }
        let text = paragraphs.joined(separator: "\n\n")
        let windows = TextWindowing.windows(for: text, maxCharacters: 80)
        #expect(windows.count > 1)
        for window in windows {
            #expect(window.count <= 80)
        }
    }

    @Test func oversizedParagraphIsSplitWithoutLosingContent() {
        let sentence = "This is a fairly long sentence that will be repeated again. "
        let text = String(repeating: sentence, count: 40)
        let windows = TextWindowing.windows(for: text, maxCharacters: 200)
        for window in windows {
            #expect(window.count <= 200)
        }
        #expect(nonWhitespace(windows.joined()) == nonWhitespace(text))
    }

    @Test func cjkTextSplitsOnGraphemeBoundariesWithinBudget() {
        let text = String(repeating: "思维阅读是一种主动的阅读方式。", count: 30)
        let windows = TextWindowing.windows(for: text, maxCharacters: 50)
        for window in windows {
            #expect(window.count <= 50)
        }
        #expect(nonWhitespace(windows.joined()) == nonWhitespace(text))
    }

    @Test func contentIsNeverDropped() {
        let text = """
        First paragraph.

        Second paragraph that is a bit longer than the first one.
        Third line in the same block.
        """
        let windows = TextWindowing.windows(for: text, maxCharacters: 30)
        #expect(nonWhitespace(windows.joined()) == nonWhitespace(text))
    }

    private func nonWhitespace(_ string: String) -> String {
        String(string.filter { !$0.isWhitespace })
    }
}
