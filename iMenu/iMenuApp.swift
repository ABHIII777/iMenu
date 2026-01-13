import SwiftUI
import CoreData
import AppKit

@main
struct iMenuApp: App {
    // Note: Core Data persistence is initialized but not currently used
    // Remove if not needed, or implement Core Data features
    let persistenceController = PersistenceController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
