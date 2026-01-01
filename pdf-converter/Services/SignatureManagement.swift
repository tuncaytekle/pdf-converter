import SwiftUI
import PencilKit
import UIKit

/// Simple persistence helper that stores signatures in `UserDefaults`.
enum SignatureStore {
    private static let storageKey = "SignatureStore.savedSignature"

    /// Value type storing the serialized PencilKit drawing and friendly name.
    struct Signature: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        private var drawingData: Data

        init(id: UUID = UUID(), name: String, drawing: PKDrawing) {
            self.id = id
            self.name = name
            self.drawingData = drawing.dataRepresentation()
        }

        var drawing: PKDrawing {
            get {
                (try? PKDrawing(data: drawingData)) ?? PKDrawing()
            }
            set {
                drawingData = newValue.dataRepresentation()
            }
        }

        func makeImage(scale: CGFloat = UIScreen.main.scale) -> UIImage? {
            let bounds = drawing.bounds
            guard !bounds.isEmpty else { return nil }

            let resolvedScale = max(scale, UIScreen.main.scale)
            return drawing.image(from: bounds, scale: resolvedScale)
        }
    }

    static func load() -> Signature? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Signature.self, from: data)
    }

    static func save(_ signature: Signature) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(signature) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// Sheet for creating or editing a signature using PencilKit.
struct SignatureEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var signature: SignatureStore.Signature?
    @State private var drawing: PKDrawing
    @State private var signatureName: String
    @State private var showEmptyAlert = false

    init(signature: Binding<SignatureStore.Signature?>) {
        _signature = signature
        let existingSignature = signature.wrappedValue
        _drawing = State(initialValue: existingSignature?.drawing ?? PKDrawing())
        _signatureName = State(initialValue: existingSignature?.name ?? NSLocalizedString("signature.defaultName", comment: "Default signature name"))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                SignatureCanvasView(drawing: $drawing)
                    .frame(height: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("signature.name.label", comment: "Signature name label"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField(NSLocalizedString("signature.name.placeholder", comment: "Signature name placeholder"), text: $signatureName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }

                Spacer()

                Text(NSLocalizedString("signature.instructions", comment: "Signature instructions"))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(signature == nil ? NSLocalizedString("signature.add.title", comment: "Add signature title") : NSLocalizedString("signature.update.title", comment: "Update signature title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("action.save", comment: "Save action")) { saveSignature() }
                        .disabled(drawing.bounds.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(NSLocalizedString("action.clear", comment: "Clear action"), role: .destructive) { drawing = PKDrawing() }
                        .disabled(drawing.bounds.isEmpty)
                }
            }
            .alert(NSLocalizedString("signature.empty.title", comment: "Empty signature title"), isPresented: $showEmptyAlert) {
                Button(NSLocalizedString("action.ok", comment: "OK action"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("signature.empty.message", comment: "Empty signature message"))
            }
        }
    }

    /// Persists the composed signature to `SignatureStore`, validating input first.
    private func saveSignature() {
        guard !drawing.bounds.isEmpty else {
            showEmptyAlert = true
            return
        }

        let trimmedName = signatureName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? NSLocalizedString("signature.defaultName", comment: "Default signature name") : trimmedName
        let existingID = signature?.id ?? UUID()

        let updatedSignature = SignatureStore.Signature(id: existingID, name: resolvedName, drawing: drawing)
        signature = updatedSignature
        dismiss()
    }
}

/// PencilKit canvas wrapper dedicated to collecting signature strokes.
struct SignatureCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        if #available(iOS 14.0, *) {
            canvas.drawingPolicy = .anyInput
        } else {
            canvas.allowsFingerDrawing = true
        }
        canvas.maximumZoomScale = 1.0
        canvas.minimumZoomScale = 1.0
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.pen, color: .label, width: 5)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private var drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}
