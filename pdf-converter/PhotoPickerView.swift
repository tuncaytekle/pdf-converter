import SwiftUI
import PhotosUI

struct PhotoPickerView: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

        init(completion: @escaping (Result<[UIImage], ScanWorkflowError>) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                picker.dismiss(animated: true) { [completion] in
                    DispatchQueue.main.async {
                        completion(.failure(.cancelled))
                    }
                }
                return
            }

            var collectedImages: [UIImage] = []
            let imageLock = NSLock()
            let dispatchGroup = DispatchGroup()

            for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                dispatchGroup.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { dispatchGroup.leave() }
                    if let image = object as? UIImage {
                        imageLock.lock()
                        collectedImages.append(image)
                        imageLock.unlock()
                    }
                }
            }

            dispatchGroup.notify(queue: .main) { [completion] in
                picker.dismiss(animated: true) {
                    if collectedImages.isEmpty {
                        completion(.failure(.noImages))
                    } else {
                        completion(.success(collectedImages))
                    }
                }
            }
        }
    }
}
