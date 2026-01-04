import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    
    final class OverlayWindow: NSWindow {
        
        var index: Int
        
        init(index: Int, contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
            self.index = index
            super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        }
        
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
    
    var overlayWindow: [NSWindow] = []
    var eventMonitor: Any?
    var selectedIndex: Int = 0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupGlobalHotkey()
    }
    
    func setupGlobalHotkey() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard
                flags.contains(.command) && flags.contains(.shift)
            else { return }
            
            DispatchQueue.main.async {
                self?.toggleOverlay()
            }
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard
                flags.contains(.command) && flags.contains(.shift)
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
            stopNavigation()
            return
        }

        createOverlay()
        overlayWindow.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        navigateWindows()
    }
    
    func moveSelection(_ delta: Int) {
        selectedIndex = (selectedIndex + delta + overlayWindow.count) % overlayWindow.count

        overlayWindow[selectedIndex].makeKey()
        
        updateWindow()
    }

    func navigateWindows() {
        guard eventMonitor == nil else {return}
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {return event}
            
            switch event.keyCode {
            case 125:
                print("Down arrow key pressed")
                self.moveSelection(+1)
                return nil
                
            case 126:
                print("Up arrow key pressed")
                self.moveSelection(-1)
                return nil
                
            default:
                print("YOUR SMART-ASS HAVEN'T EVEN WRITTEN THAT CODE.")
                return event
            }
            
        }
    }
    
    func stopNavigation() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
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
            
            let spacing: CGFloat = 80
            let totalHeight = CGFloat(apps.count) * spacing

            let x = screenFrame.midX
            let startY = screenFrame.midY + (totalHeight / 2) - (spacing / 2)
            let y = startY - CGFloat(index) * spacing

            
            let window = OverlayWindow(
                index: index,
                contentRect: NSRect(
                    origin: CGPoint(
                        x: x - windowSize.width / 2,
                        y: y - windowSize.height / 2
                    ),
                    size: windowSize
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
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
    
    func updateWindow() {
        
        let normalSize = NSSize(width: 320, height: 100)
        let updatedSize = NSSize(width: 350, height: 130)
        
        let spacing: CGFloat = 80
        guard let screen = NSScreen.main else { return }
        
        let totalHeight =
            overlayWindow.reduce(0) { sum, _ in
                sum + normalSize.height + spacing
            } - spacing

        let startY = screen.visibleFrame.midY + totalHeight / 2
        
        for (index, window) in overlayWindow.enumerated(){
            let isSelected = (index == selectedIndex)
            let size = isSelected ? normalSize : updatedSize
            
            let y = startY - CGFloat(index) * (normalSize.height + spacing) - size.height / 2

            let x = screen.visibleFrame.midX - size.width / 2

            window.setFrame(
                NSRect(origin:
                    CGPoint(x: x, y: y),size: size),
                    display: true,
                    animate: true
            )
        }
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
