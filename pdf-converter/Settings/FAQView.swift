import SwiftUI

struct FAQView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("faq.header.title", comment: "FAQ header title"))
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text(NSLocalizedString("faq.header.subtitle", comment: "FAQ header subtitle"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // FAQ Sections
                    ForEach(FAQSection.allSections, id: \.title) { section in
                        FAQSectionView(section: section, searchText: searchText)
                    }
                }
                .padding(.bottom, 32)
            }
            .searchable(text: $searchText, prompt: NSLocalizedString("faq.search.prompt", comment: "Search FAQ prompt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("action.done", comment: "Done action")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct FAQSectionView: View {
    let section: FAQSection
    let searchText: String

    var filteredItems: [FAQItem] {
        if searchText.isEmpty {
            return section.items
        }
        return section.items.filter { item in
            item.question.localizedCaseInsensitiveContains(searchText) ||
            item.answer.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        if !filteredItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // Section Header
                Text(section.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Questions
                VStack(spacing: 0) {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.question) { index, item in
                        FAQItemView(item: item)

                        if index < filteredItems.count - 1 {
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                .padding(.horizontal)
            }
        }
    }
}

struct FAQItemView: View {
    let item: FAQItem
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(item.answer)
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(item.question)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

// MARK: - Data Models

struct FAQSection {
    let title: String
    let items: [FAQItem]

    static var allSections: [FAQSection] {
        [
            FAQSection(
                title: NSLocalizedString("faq.section.gettingStarted", comment: "Getting Started section"),
                items: [
                    FAQItem(
                        question: NSLocalizedString("faq.gettingStarted.blueButton.question", comment: "Blue button question"),
                        answer: NSLocalizedString("faq.gettingStarted.blueButton.answer", comment: "Blue button answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.gettingStarted.advancedTools.question", comment: "Advanced tools question"),
                        answer: NSLocalizedString("faq.gettingStarted.advancedTools.answer", comment: "Advanced tools answer")
                    )
                ]
            ),
            FAQSection(
                title: NSLocalizedString("faq.section.converting", comment: "Converting & Scanning section"),
                items: [
                    FAQItem(
                        question: NSLocalizedString("faq.converting.formats.question", comment: "File formats question"),
                        answer: NSLocalizedString("faq.converting.formats.answer", comment: "File formats answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.converting.quality.question", comment: "Document quality question"),
                        answer: NSLocalizedString("faq.converting.quality.answer", comment: "Document quality answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.converting.webPage.question", comment: "Web page question"),
                        answer: NSLocalizedString("faq.converting.webPage.answer", comment: "Web page answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.converting.multiPage.question", comment: "Multi-page question"),
                        answer: NSLocalizedString("faq.converting.multiPage.answer", comment: "Multi-page answer")
                    )
                ]
            ),
            FAQSection(
                title: NSLocalizedString("faq.section.editing", comment: "Editing & Signatures section"),
                items: [
                    FAQItem(
                        question: NSLocalizedString("faq.editing.signature.question", comment: "Signature question"),
                        answer: NSLocalizedString("faq.editing.signature.answer", comment: "Signature answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.editing.highlight.question", comment: "Highlight question"),
                        answer: NSLocalizedString("faq.editing.highlight.answer", comment: "Highlight answer")
                    )
                ]
            ),
            FAQSection(
                title: NSLocalizedString("faq.section.fileManagement", comment: "File Management section"),
                items: [
                    FAQItem(
                        question: NSLocalizedString("faq.fileManagement.organize.question", comment: "Organize question"),
                        answer: NSLocalizedString("faq.fileManagement.organize.answer", comment: "Organize answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.fileManagement.actions.question", comment: "File actions question"),
                        answer: NSLocalizedString("faq.fileManagement.actions.answer", comment: "File actions answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.fileManagement.import.question", comment: "Import question"),
                        answer: NSLocalizedString("faq.fileManagement.import.answer", comment: "Import answer")
                    )
                ]
            ),
            FAQSection(
                title: NSLocalizedString("faq.section.account", comment: "Account & Support section"),
                items: [
                    FAQItem(
                        question: NSLocalizedString("faq.account.subscription.question", comment: "Subscription question"),
                        answer: NSLocalizedString("faq.account.subscription.answer", comment: "Subscription answer")
                    ),
                    FAQItem(
                        question: NSLocalizedString("faq.account.support.question", comment: "Support question"),
                        answer: NSLocalizedString("faq.account.support.answer", comment: "Support answer")
                    )
                ]
            )
        ]
    }
}

struct FAQItem {
    let question: String
    let answer: String
}

#Preview {
    FAQView()
}
