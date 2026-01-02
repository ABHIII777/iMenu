//
//  iMenuApp.swift
//  iMenu
//
//  Created by Abhi Patel on 02/01/26.
//

import SwiftUI
import CoreData

@main
struct iMenuApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
