//
//  StateBoxes.swift
//  Empty
//
//  Reference boxes for values that live inside `@State` but must NOT
//  invalidate the view when they change. Assigning a new value to a
//  `@State var task: Task?` re-renders the whole view tree — fatal when
//  it happens per mouse-move or per scroll frame; mutating a class's
//  contents does not.
//

import Foundation

@MainActor
final class TaskBox {
    var task: Task<Void, Never>?

    func replace(_ newTask: Task<Void, Never>?) {
        task?.cancel()
        task = newTask
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Mutable dictionary cache held by reference (writes don't re-render).
@MainActor
final class DictionaryBox<Key: Hashable, Value> {
    var values: [Key: Value] = [:]

    // Explicit empty deinit works around a Swift 6.2 release-build crash in
    // the synthesized generic deinit (rdar://TBD — EarlyPerfInliner assertion).
    deinit {}
}
