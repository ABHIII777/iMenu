import SwiftUI
import AppKit
import CoreGraphics
import Cocoa
import ScreenCaptureKit

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
    var globalEventMonitor: Any?
    var localEventMonitor: Any?
    var selectedIndex: Int = 0
    var windowStreams: [SCWindow: SCStream] = [:]
    var streamOutputs: [SCWindow: AnyObject] = [:]

    var wasCmdShiftPressed = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure app to run as background/menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        setupGlobalHotkey()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up all streams before app terminates
        for stream in windowStreams.values {
            stream.stopCapture()
        }
        windowStreams.removeAll()
        stopNavigation()
    }
    
    func setupGlobalHotkey() {
        // Global monitor for when app is not active
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        
        // Local monitor for when app is active
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }
    }
    
    @MainActor
    func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmdShiftPressed = flags.contains(.command) && flags.contains(.shift)
        
        // Only trigger on press, not release
        if isCmdShiftPressed && !wasCmdShiftPressed {
            toggleOverlay()
        }
        
        wasCmdShiftPressed = isCmdShiftPressed
    }
    
//    func ensureAuthorization(completion: @escaping (Bool) -> Void) {
//        let status = SCShareableContent.authorizationStatus
//        switch status {
//        case .authorized:
//            completion(true)
//        case .notDetermined:
//            SCShareableContent.requestAuthorization { granted in
//                completion(granted)
//            }
//        case .denied:
//            print("Screen capture permission denied")
//            completion(false)
//        @unknown default:
//            completion(false)
//        }
//    }

    func ensureAuthorization(completion: @escaping (Bool) -> Void) {
        if CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.async {
                completion(true)
            }
        } else {
            DispatchQueue.main.async {
                let granted = CGRequestScreenCaptureAccess()
                completion(granted)
            }
        }
    }
    
    func toggleOverlay() {
//        if overlayWindow.contains(where: { $0.isVisible }) {
//            overlayWindow.forEach { $0.orderOut(nil) }
//            stopNavigation()
//            return
//        }
//
//        createOverlay()
//        overlayWindow.forEach { $0.makeKeyAndOrderFront(nil) }
//        NSApp.activate(ignoringOtherApps: true)
//        navigateWindows()
        
        ensureAuthorization { [weak self] granted in
            guard let self = self, granted else {return}
            
            if self.overlayWindow.contains(where: {$0.isVisible}) {
                self.overlayWindow.forEach{$0.orderOut(nil)}
                self.stopNavigation()
                return
            }
            
            self.createOverlay()
            self.overlayWindow.forEach{$0.makeKeyAndOrderFront(nil)}
            
            NSApp.activate(ignoringOtherApps: true)
            
            self.navigateWindows()
            self.captureWindow()
        }

    }
    
    func moveSelection(_ delta: Int) {
        guard !overlayWindow.isEmpty else { return }
        
        selectedIndex = (selectedIndex + delta + overlayWindow.count) % overlayWindow.count
        
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated && !app.isHidden
        }
        
        guard apps.count == overlayWindow.count else { return }
        
        for (index, window) in overlayWindow.enumerated() {
            guard index < apps.count,
                  let host = window.contentView as? NSHostingView<RunningApps> else { continue }
            host.rootView = RunningApps(
                app: apps[index],
                isSelected: index == selectedIndex,
                preview: host.rootView.preview
            )
        }

        guard selectedIndex < overlayWindow.count else { return }
        overlayWindow[selectedIndex].makeKey()
    }

    var navigationMonitor: Any?
    
    func navigateWindows() {
        // Remove existing navigation monitor if any
        stopNavigation()
        
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {return event}
            
            switch event.keyCode {
            case 125: // Down arrow
                self.moveSelection(+1)
                return nil
                
            case 126: // Up arrow
                self.moveSelection(-1)
                return nil
                
            case 36, 76: // Enter or Return
                self.activateWindow()
                self.toggleOverlay()
                return nil
                
            default:
                return event
            }
        }
    }
    
    func stopNavigation() {
        if let monitor = navigationMonitor {
            NSEvent.removeMonitor(monitor)
            navigationMonitor = nil
        }
    }
    
    func activateWindow() {
        
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated && !app.isHidden
        }
        
        guard selectedIndex >= 0 && selectedIndex < apps.count else { return }
        let app = apps[selectedIndex]
        app.activate(options: [.activateAllWindows])
    }
    
    func createOverlay() {
        assert(Thread.isMainThread, "createOverlay must be called on main thread")
        
        
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated && !app.isHidden
        }
        
        guard !apps.isEmpty else { return }

        let windowSize = NSSize(width: 320, height: 100)
        
        
        overlayWindow.forEach { $0.close() }
        overlayWindow.removeAll()
        selectedIndex = 0  // Reset selection when creating new overlay
        
        
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
                rootView: RunningApps(app: app, isSelected: (index == selectedIndex), preview: nil)
            )
            
            overlayWindow.append(window)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func snapshot(of window: SCWindow, completion: @escaping (NSImage?) -> Void) {
        guard window.frame.width > 0 && window.frame.height > 0 else {
            completion(nil)
            return
        }

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.scalesToFit = true

        guard let filter = try? SCContentFilter(desktopIndependentWindow: window) else {
            completion(nil)
            return
        }
        
        guard let stream = try? SCStream(filter: filter, configuration: config, delegate: nil) else {
            completion(nil)
            return
        }
        
        windowStreams[window] = stream

        final class Output: NSObject, SCStreamOutput {
            let handler: (NSImage?) -> Void
            let stream: SCStream
            weak var delegate: AppDelegate?
            let window: SCWindow

            init(stream: SCStream, handler: @escaping (NSImage?) -> Void, delegate: AppDelegate?, window: SCWindow) {
                self.stream = stream
                self.handler = handler
                self.delegate = delegate
                self.window = window
            }

            func stream(_ stream: SCStream,
                        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                        of type: SCStreamOutputType) {
                guard let pb = sampleBuffer.imageBuffer else {
                    handler(nil)
                    stream.stopCapture()
                    Task { @MainActor in
                        self.delegate?.windowStreams.removeValue(forKey: self.window)
                    }
                    return
                }

                let ci = CIImage(cvPixelBuffer: pb)
                let ctx = CIContext()
                guard let cgImage = ctx.createCGImage(ci, from: ci.extent) else {
                    handler(nil)
                    stream.stopCapture()
                    Task { @MainActor in
                        self.delegate?.windowStreams.removeValue(forKey: self.window)
                    }
                    return
                }
                
                let img = NSImage(cgImage: cgImage, size: .zero)
                handler(img)
                stream.stopCapture()
                
                // Clean up stream from dictionary
                Task { @MainActor in
                    self.delegate?.windowStreams.removeValue(forKey: self.window)
                    self.delegate?.streamOutputs.removeValue(forKey: self.window)
                }
            }
        }

        let output = Output(stream: stream, handler: completion, delegate: self, window: window)
        
        streamOutputs[window] = output

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
            try stream.startCapture()
        } catch {
            windowStreams.removeValue(forKey: window)
            streamOutputs.removeValue(forKey: window)
            completion(nil)
        }
        
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
            try stream.startCapture()
        } catch {
            windowStreams.removeValue(forKey: window)
            completion(nil)
        }

    }
    
    func captureWindow() {
        // Small delay to ensure windows are fully created and visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                let scWindows = content?.windows ?? []
                let apps = NSWorkspace.shared.runningApplications.filter {
                    $0.activationPolicy == .regular && !$0.isTerminated && !$0.isHidden
                }

                Task { @MainActor in
                    for (index, app) in apps.enumerated() {
                        guard index < self.overlayWindow.count else { continue }

                        if let scWindow = scWindows.first(where: { $0.owningApplication?.bundleIdentifier == app.bundleIdentifier }) {
                            self.snapshot(of: scWindow) { image in
                                Task { @MainActor in
                                    if let host = self.overlayWindow[index].contentView as? NSHostingView<RunningApps> {
                                        host.rootView = RunningApps(app: app, isSelected: index == self.selectedIndex, preview: image)
                                    }
                                }
                            }
                        }
                    }
                }
            }
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
        var isSelected: Bool
        var preview: NSImage?

        var body: some View {
            HStack(alignment: .center, spacing: 0) {
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
                .frame(width: 320)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    isSelected ? Color.accentColor : .clear,
                                    lineWidth: 3
                                )
                        )
                )
                .scaleEffect(isSelected ? 1.05 : 1.0)
                .shadow(radius: isSelected ? 20 : 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
                .cornerRadius(14)
                
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 320, height: 100)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(
                                            Color.accentColor,
                                            lineWidth: 3
                                        )
                                )
                        )
                        .cornerRadius(14)
                        .padding(.leading, 24)
                }
            }
        }
    }
    
    deinit {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = navigationMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
