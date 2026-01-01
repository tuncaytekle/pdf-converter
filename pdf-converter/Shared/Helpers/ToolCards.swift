import SwiftUI

struct ToolCardView: View {
    let card: ToolCard

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(card.tint)
                .shadow(radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.95))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: card.iconName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(card.tint)
                        )

                    Spacer(minLength: 0)

                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(card.tint)
                        )
                }

                Text(card.title)
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.9)

                Spacer()
            }
            .padding(16)
        }
        .aspectRatio(1.05, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ToolCard: Identifiable {
    let id = UUID()
    let title: String
    let tint: Color
    let iconName: String
    let action: ToolAction?
}

extension ToolCard {
    static let sample: [ToolCard] = [
        .init(title: NSLocalizedString("tools.card.convertFiles.title", comment: "Convert files title"),
              tint: Color(hex: 0x2F7F79),
              iconName: "infinity",
              action: .convertFiles),
        .init(title: NSLocalizedString("tools.card.scan.title", comment: "Scan documents title"),
              tint: Color(hex: 0xC02267),
              iconName: "camera",
              action: .scanDocuments),
        .init(title: NSLocalizedString("tools.card.convertPhotos.title", comment: "Convert photos title"),
              tint: Color(hex: 0x5C3A78),
              iconName: "photo.on.rectangle",
              action: .convertPhotos),
        .init(title: NSLocalizedString("tools.card.import.title", comment: "Import documents title"),
              tint: Color(hex: 0x6C8FC0),
              iconName: "arrow.down.to.line",
              action: .importDocuments),
        .init(title: NSLocalizedString("tools.card.web.title", comment: "Convert web page title"),
              tint: Color(hex: 0xBF7426),
              iconName: "link",
              action: .convertWebPage),
        .init(title: NSLocalizedString("tools.card.edit.title", comment: "Edit documents title"),
              tint: Color(hex: 0x7B3DD3),
              iconName: "pencil.and.outline",
              action: .editDocuments)
    ]
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
