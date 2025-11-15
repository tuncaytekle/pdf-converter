import SwiftUI
import CoreData

/// Entry point for the SwiftUI app; injects the shared Core Data controller.
@main
struct PDFConverterApp: App {
    private let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
