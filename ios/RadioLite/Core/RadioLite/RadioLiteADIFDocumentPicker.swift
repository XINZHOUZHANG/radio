import Foundation
import SwiftUI
import UIKit

enum RadioLiteDocumentPickerError: LocalizedError {
    case noDocumentSelected

    var errorDescription: String? {
        "文件选择器没有返回文件。"
    }
}

struct RadioLiteADIFDocumentPicker: UIViewControllerRepresentable {
    var onResult: (Result<URL, Error>) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: RadioLiteADIFDocument.allowedContentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {
        context.coordinator.onResult = onResult
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onResult: (Result<URL, Error>) -> Void
        var onCancel: () -> Void
        private var hasCompleted = false

        init(
            onResult: @escaping (Result<URL, Error>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onResult = onResult
            self.onCancel = onCancel
            super.init()
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard !hasCompleted else { return }
            hasCompleted = true
            guard let url = urls.first else {
                onResult(.failure(RadioLiteDocumentPickerError.noDocumentSelected))
                return
            }
            onResult(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onCancel()
        }
    }
}
