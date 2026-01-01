import Testing
@testable import pdf_converter

@Suite("Analytics-driven behaviors")
struct PDFConverterTests {
    @MainActor
    @Test("TabNavigationViewModel logs transitions when the tab changes")
    func tabSwitchTrackingRecordsTransitions() async throws {
        let analytics = AnalyticsSpy()
        let sut = TabNavigationViewModel()

        sut.trackTabIfNeeded(analytics: analytics, tab: .files)
        sut.trackTabIfNeeded(analytics: analytics, tab: .tools)

        #expect(analytics.capturedEvents.count == 1)
        let event = try #require(analytics.capturedEvents.first)
        #expect(event.name == "tab_switched")
        #expect(event.properties["from"] as? String == "files")
        #expect(event.properties["to"] as? String == "tools")
    }

    @MainActor
    @Test("TabNavigationViewModel ignores duplicate tab updates")
    func tabSwitchTrackingIgnoresDuplicateTabs() async throws {
        let analytics = AnalyticsSpy()
        let sut = TabNavigationViewModel()

        sut.trackTabIfNeeded(analytics: analytics, tab: .files)
        sut.trackTabIfNeeded(analytics: analytics, tab: .files)

        #expect(analytics.capturedEvents.isEmpty)
    }

    @MainActor
    @Test("ConversionViewModel only includes optional properties when present")
    func conversionTrackingIncludesOptionalMetadata() async throws {
        let analytics = AnalyticsSpy()
        let sut = ConversionViewModel()

        sut.trackFileConversionResult(
            analytics: analytics,
            source: "share_sheet",
            result: "success",
            failureCategory: nil,
            durationMs: 1200
        )

        let event = try #require(analytics.capturedEvents.last)
        #expect(event.name == "file_conversion_result")
        #expect(event.properties["source"] as? String == "share_sheet")
        #expect(event.properties["result"] as? String == "success")
        #expect(event.properties["duration_ms"] as? Int == 1200)
        #expect(event.properties["failure_category"] == nil)
    }
}

private final class AnalyticsSpy: AnalyticsTracking {
    private(set) var capturedEvents: [(name: String, properties: [String: Any])] = []

    func identify(_ distinctId: String) { }

    func capture(_ event: String, properties: [String: Any]) {
        capturedEvents.append((event, properties))
    }

    func screen(_ name: String, properties: [String: Any]) { }
}
