//
//  SummarizationPipeline.swift
//  Empty
//

import Foundation

/// Provider-agnostic map-reduce summarization.
///
/// Windows the text to the provider's budget, condenses window by window,
/// re-windows the partials until everything fits one window, then runs the
/// focus-specific final pass. Throws `.emptyInput` for whitespace-only text
/// and `.inputTooLarge` when a reduce pass stops shrinking (pathological
/// input would otherwise loop forever).
enum SummarizationPipeline {
    static func run(
        text: String,
        windowBudget: Int,
        condense: (String) async throws -> String,
        finish: (String) async throws -> String
    ) async throws -> String {
        var pieces = TextWindowing.windows(for: text, maxCharacters: windowBudget)
        guard !pieces.isEmpty else { throw AIServiceError.emptyInput }

        while pieces.count > 1 {
            var partials: [String] = []
            partials.reserveCapacity(pieces.count)
            for piece in pieces {
                partials.append(try await condense(piece))
            }
            let merged = TextWindowing.windows(
                for: partials.joined(separator: "\n\n"),
                maxCharacters: windowBudget
            )
            guard merged.count < pieces.count else { throw AIServiceError.inputTooLarge }
            pieces = merged
        }
        return try await finish(pieces[0])
    }
}
