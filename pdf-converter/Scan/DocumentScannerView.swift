import SwiftUI
import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) { }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

        init(completion: @escaping (Result<[UIImage], ScanWorkflowError>) -> Void) {
            self.completion = completion
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images: [UIImage] = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true) { [completion] in
                DispatchQueue.main.async {
                    if images.isEmpty {
                        completion(.failure(.noImages))
                    } else {
                        completion(.success(images))
                    }
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) { [completion] in
                DispatchQueue.main.async {
                    completion(.failure(.cancelled))
                }
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true) { [completion] in
                DispatchQueue.main.async {
                    completion(.failure(.underlying(error)))
                }
            }
        }
    }
}
