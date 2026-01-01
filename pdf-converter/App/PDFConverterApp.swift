import SwiftUI
import CoreData
import PostHog

/// Entry point for the SwiftUI app; injects the shared Core Data controller.
@main
struct PDFConverterApp: App {
    private let persistenceController = PersistenceController.shared
    private let tracker: AnalyticsTracking
    @StateObject private var cloudSyncStatus = CloudSyncStatus()

    init() {
        let POSTHOG_API_KEY = "phc_FQdK7M4eYcjjhgNYiHScD1OoeOyYFVMwqWR2xvoq4yR"
        // usually 'https://us.i.posthog.com' or 'https://eu.i.posthog.com'
        let POSTHOG_HOST = "https://us.i.posthog.com"
        
        
        let config = PostHogConfig(apiKey: POSTHOG_API_KEY, host: POSTHOG_HOST)
        
        // check https://posthog.com/docs/session-replay/installation?tab=iOS
        // for more config and to learn about how we capture sessions on mobile
        // and what to expect
        config.sessionReplay = true
        // choose whether to mask images or text
        config.sessionReplayConfig.maskAllImages = true
        config.sessionReplayConfig.maskAllTextInputs = true
        // screenshot is disabled by default
        // The screenshot may contain sensitive information, use with caution
        config.sessionReplayConfig.screenshotMode = true
        config.captureElementInteractions = true // Disabled by default
        config.captureApplicationLifecycleEvents = true // Disabled by default
        config.captureScreenViews = false // Disabled - using manual .postHogScreenView() instead
        
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.capture("Test Event")
        let anonId = AnonymousIdProvider.getOrCreate()

        let t = PostHogTracker()
        t.identify(anonId)
        self.tracker = t
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.analytics, tracker)
                .environmentObject(cloudSyncStatus)
        }
    }
}
