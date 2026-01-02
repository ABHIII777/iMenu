import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    
    final class OverlayWindow: NSWindow {
        
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
    
    var overlayWindow: [NSWindow] = []
    var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupGlobalHotkey()
    }
    
    func setupGlobalHotkey() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                event.modifierFlags.contains([.command, .shift]),
                event.charactersIgnoringModifiers?.lowercased() == "o"
            else { return }
            
            DispatchQueue.main.async {
                self?.toggleOverlay()
            }
        }
        

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                event.modifierFlags.contains([.command, .shift]),
                event.charactersIgnoringModifiers?.lowercased() == "o"
            else {return event}
            
            DispatchQueue.main.async {
                self?.toggleOverlay()
            }
            return nil
        }
    }
    
    func toggleOverlay() {
        if overlayWindow.contains(where: { $0.isVisible }) {
            overlayWindow.forEach { $0.orderOut(nil) }
            return
        }

        createOverlay()
        overlayWindow.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }


    func createOverlay() {
        assert(Thread.isMainThread, "createOverlay must be called on main thread")
        
        
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated && !app.isHidden
        }

        let windowSize = NSSize(width: 320, height: 100)
        
        
        overlayWindow.forEach { $0.close() }
        overlayWindow.removeAll()
        
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        
        for (index, app) in apps.enumerated() {
            
            let spacing: CGFloat = windowSize.height + 12
            let totalHeight = CGFloat(apps.count) * spacing

            let x = screenFrame.midX
            let startY = screenFrame.midY + (totalHeight / 2) - (spacing / 2)
            let y = startY - CGFloat(index) * spacing

            
            let window = OverlayWindow(
                contentRect: NSRect(
                    origin: CGPoint(
                        x: x - windowSize.width / 2,
                        y: y - windowSize.height / 2
                    ),
                    size: windowSize
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            
            window.contentView = NSHostingView(
                rootView: RunningApps(app: app)
            )
            
            overlayWindow.append(window)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    struct AppIconView: View {
        var nsImage: NSImage
        var appName: String
        
        var body: some View {
            VStack {
                Image(nsImage: nsImage)
                Text(appName)
            }
        }
    }
    
    struct RunningApps: View {
        var app: NSRunningApplication

        var body: some View {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                }

                Text(app.localizedName ?? "")
                    .font(.system(size: 14, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(14)
        }
    }

    
    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
