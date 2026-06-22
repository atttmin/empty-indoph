//
//  DocumentPickerPresenter.swift
//  Empty
//
//  Presents UIDocumentPickerViewController from the key window's root,
//  bypassing SwiftUI's view hierarchy entirely.
//

#if !os(macOS)

import UIKit
import UniformTypeIdentifiers

/// Presents a document picker on the key window's top-most view controller.
/// The completion is called on the main actor.
@MainActor
enum DocumentPickerPresenter {
    static func pick(
        contentTypes: [UTType],
        allowsMultiple: Bool,
        completion: @escaping (Result<[URL], Error>) -> Void
    ) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = windowScene.windows.first?.rootViewController else {
            completion(.failure(PickerError.noWindow))
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = allowsMultiple

        let coordinator = PickerCoordinator(completion: completion)
        // Retain via objc association so the delegate lives until dismissal.
        objc_setAssociatedObject(picker, &coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
        picker.delegate = coordinator

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(picker, animated: true)
    }

    private static var coordinatorKey: UInt8 = 0

    private class PickerCoordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<[URL], Error>) -> Void

        init(completion: @escaping (Result<[URL], Error>) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }

    enum PickerError: LocalizedError {
        case noWindow
        var errorDescription: String? { "No window scene available" }
    }
}

#endif
