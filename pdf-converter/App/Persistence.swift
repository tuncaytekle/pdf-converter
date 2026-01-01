import CoreData

/// Wraps the Core Data stack so SwiftUI can request a single shared container.
struct PersistenceController {
    /// Production singleton used by the live app.
    static let shared = PersistenceController()

    /// In-memory variant that powers SwiftUI previews and tests.
    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        for _ in 0..<10 {
            let newItem = Item(context: context)
            newItem.timestamp = Date()
        }
        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            assertionFailure("Preview seed failed: \(nsError), \(nsError.userInfo)")
        }
        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "PDFConverter")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved Core Data error: \(error.localizedDescription)")
            }
        }

        // Merge background saves into the view context so SwiftUI lists stay in sync.
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
