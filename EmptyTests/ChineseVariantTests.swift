//
//  ChineseVariantTests.swift
//  EmptyTests
//

import Testing
@testable import Empty

struct ChineseVariantTests {
    @Test func convertsSimplifiedToTraditional() {
        #expect(ChineseVariant.traditional("万里长城") == "萬里長城")
        #expect(ChineseVariant.traditional("读书") == "讀書")
    }

    @Test func leavesNonChineseAndTraditionalAlone() {
        #expect(ChineseVariant.traditional("Hello, world!") == "Hello, world!")
        #expect(ChineseVariant.traditional("萬卷書") == "萬卷書")
    }
}
