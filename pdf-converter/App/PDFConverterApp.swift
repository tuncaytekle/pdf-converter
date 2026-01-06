import SwiftUI
import CoreData
import PostHog

/// App delegate to control orientation locking
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Lock to portrait orientations only
        return .portrait
    }
}

/// Entry point for the SwiftUI app; injects the shared Core Data controller.
@main
struct PDFConverterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let persistenceController = PersistenceController.shared
    private let tracker: AnalyticsTracking
    @StateObject private var cloudSyncStatus = CloudSyncStatus()
    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var subscriptionGate: SubscriptionGate
    private let ratingPromptManager = RatingPromptManager()
    private let ratingPromptCoordinator: RatingPromptCoordinator

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

        // Initialize subscription system
        let subManager = SubscriptionManager()
        _subscriptionManager = StateObject(wrappedValue: subManager)
        _subscriptionGate = StateObject(wrappedValue: SubscriptionGate(subscriptionManager: subManager))

        // Initialize rating prompt system
        self.ratingPromptCoordinator = RatingPromptCoordinator(manager: ratingPromptManager)

        ASAUploader.sendIfNeeded()
    }
    var body: some Scene {
        WindowGroup {
            ContentView(ratingPromptCoordinator: ratingPromptCoordinator, ratingPromptManager: ratingPromptManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.analytics, tracker)
                .environmentObject(cloudSyncStatus)
                .environmentObject(subscriptionManager)
                .environmentObject(subscriptionGate)
        }
    }
}
