//
//  uitest_bottombarApp.swift
//  uitest-bottombar
//
//  Created by Tuncay Tekle on 10/9/25.
//

import SwiftUI
import CoreData

@main
struct uitest_bottombarApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
