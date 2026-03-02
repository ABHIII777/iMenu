import SwiftUI
import AppKit
import CoreGraphics
import Cocoa
import ScreenCaptureKit
import Darwin

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    final class OverlayWindow: NSWindow {
        var index: Int
        
        init(index: Int, contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
            self.index = index
            super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        }
        
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    
    final class NonKeyWindow: NSWindow {
        var index: Int
        
        init(index: Int, contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
            self.index = index
            super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        }
        
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    var overlayWindow: [NSWindow] = []
    var previewWindow: NSWindow?
    var systemMonitorWindow: NSWindow?
    var cachedApps: [NSRunningApplication] = []
    var cachedWindows: [WindowItem] = []
    var windowPreviews: [SCWindow: NSImage] = [:]
    var selectedIndex: Int = 0
    var lastActiveAppID: String?

    var windows: [SCWindow] = []
    var selectedWindow: SCWindow?

    var terminationObserver: Any?

    var globalEventMonitor: Any?
    var localEventMonitor: Any?
    var navigationMonitor: Any?

    var wasCmdShiftPressed = false
    var wasControlOptionPressed = false

    var windowStreams: [SCWindow: SCStream] = [:]
    var streamOutputs: [SCWindow: AnyObject] = [:]

    let ciContext = CIContext()
    
    let monitorSize = NSSize(width: 220, height: 150)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for stream in windowStreams.values {
            stream.stopCapture()
        }
        windowStreams.removeAll()
        streamOutputs.removeAll()
        
        stopNavigation()
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    func setupGlobalHotkey() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleFlagsChanged(event) }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmdShiftPressed = flags.contains(.command) && flags.contains(.option)
        let isControlOptionPressed = flags.contains(.control) && flags.contains(.option)

        if isCmdShiftPressed && !wasCmdShiftPressed {
            toggleOverlay()
        }
        
        if isControlOptionPressed && !wasControlOptionPressed {
            iClip.shared.toggleOverlay()
        }

        wasCmdShiftPressed = isCmdShiftPressed
        wasControlOptionPressed = isControlOptionPressed
    }

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
        ensureAuthorization { [weak self] granted in
            guard let self = self, granted else { return }

            if self.overlayWindow.contains(where: { $0.isVisible }) {
                self.overlayWindow.forEach { $0.orderOut(nil) }
                self.previewWindow?.orderOut(nil)
                self.systemMonitorWindow?.orderOut(nil)
                self.stopNavigation()
                NSApp.setActivationPolicy(.accessory)
                return
            }

            self.refreshWindowsAndOverlay()
        }
    }

    func refreshWindowsAndOverlay() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self, let content else { return }

            let filtered = content.windows.filter { w in
                // Must have a valid owning application
                guard let scApp = w.owningApplication else { return false }
                // Bridge to NSRunningApplication to access activationPolicy/isHidden
                guard let nsApp = NSRunningApplication(processIdentifier: scApp.processID) else { return false }
                // Only user-facing apps
                guard nsApp.activationPolicy == .regular else { return false }
                // Exclude hidden apps
                if nsApp.isHidden { return false }
                // Exclude zero/too-small windows
                if w.frame.width <= 50 || w.frame.height <= 50 { return false }
                // Exclude windows that are offscreen (no intersection with any screen)
                if let screen = NSScreen.screens.first(where: { NSIntersectionRect($0.visibleFrame, w.frame).isEmpty == false }) {
                    _ = screen // keep the screen reference to signal it exists
                } else {
                    return false
                }
                // Exclude desktop, loginwindow, and system UI windows by bundle ID heuristics
                if let bundleID = nsApp.bundleIdentifier {
                    let disallowedPrefixes = [
                        "com.apple.loginwindow",
                        "com.apple.WindowServer",
                        "com.apple.notificationcenterui",
                        "com.apple.controlcenter",
                        "com.apple.dock",
                        "com.apple.Spotlight",
                        "com.apple.ScreenTimeAgent",
                        "com.apple.WebKit.WebContent",
                        "com.apple.WebKit.Networking",
                        "com.apple.Safari.WebFeedParser",
                        "com.apple.Safari.SandboxBroker",
                        "com.apple.finder",
                        "com.microsoft.VSCode"
                    ]
                    if disallowedPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                        return false
                    }
                }
                // Exclude untitled background helpers with no title
                if (w.title?.isEmpty ?? true) && (w.owningApplication?.applicationName.isEmpty ?? true) {
                    return false
                }
                return true
            }

            // Sort by app name, then by Y (top-most first)
            let sorted = filtered.sorted { a, b in
                let aName = a.owningApplication?.applicationName ?? ""
                let bName = b.owningApplication?.applicationName ?? ""
                if aName != bName { return aName < bName }
                return a.frame.origin.y > b.frame.origin.y
            }

            Task { @MainActor in
                self.windows = sorted
                self.selectedIndex = 0
                self.buildOverlay(from: sorted)
                self.selectedWindow = self.windows.first
                self.captureSelectedWindowPreview()

                self.previewWindow?.orderFront(nil)
                self.systemMonitorWindow?.orderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.navigateWindows()
            }
        }
    }

    func buildOverlay(from windows: [SCWindow]) {
        overlayWindow.forEach { $0.close() }
        overlayWindow.removeAll()
        previewWindow?.close(); previewWindow = nil
        systemMonitorWindow?.close(); systemMonitorWindow = nil

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = NSSize(width: 320, height: 100)
        let spacing: CGFloat = 80
        let totalHeight = CGFloat(windows.count) * spacing
        let startY = screenFrame.midY + (totalHeight / 2) - (spacing / 2)

        for (index, scWindow) in windows.enumerated() {
            let y = startY - CGFloat(index) * spacing

            let window = OverlayWindow(
                index: index,
                contentRect: NSRect(
                    origin: CGPoint(
                        x: screenFrame.midX - windowSize.width / 2,
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
            window.isReleasedWhenClosed = false

            window.contentView = NSHostingView(
                rootView: WindowRow(window: scWindow, isSelected: index == selectedIndex)
            )

            overlayWindow.append(window)
            window.makeKeyAndOrderFront(nil)
        }

        createPreviewWindow()
        createSystemMonitorWindow()
    }

    func updatePreviewPosition() {
        guard let previewWindow = previewWindow,
              selectedIndex < overlayWindow.count else { return }
        
        let selectedWindow = overlayWindow[selectedIndex]
        let selectedFrame = selectedWindow.frame
        let previewSize = previewWindow.frame.size
        
        let newOrigin = CGPoint(
            x: selectedFrame.maxX + 20,
            y: selectedFrame.midY - previewSize.height / 2
        )
        
        previewWindow.setFrameOrigin(newOrigin)
    }
    
    func updateSystemMonitorPosition() {
        guard let systemMonitorWindow,
              selectedIndex < overlayWindow.count else { return }
        
        let selectedWindow = overlayWindow[selectedIndex]
        let selectedFrame = selectedWindow.frame
        
        let newOrigin = CGPoint(
            x: selectedFrame.midX - monitorSize.width - 20,
            y: selectedFrame.midY - monitorSize.height / 2
        )
        
        systemMonitorWindow.setFrameOrigin(newOrigin)
    }

    func updateSelectionUI() {
        for (index, window) in overlayWindow.enumerated() {
            if let host = window.contentView as? NSHostingView<WindowRow> {
                let old = host.rootView
                host.rootView = WindowRow(window: old.window, isSelected: index == selectedIndex)
            }
        }
        
        updatePreviewPosition()
        updateSystemMonitorPosition()
    }

    func moveSelection(_ delta: Int) {
        guard !overlayWindow.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + overlayWindow.count) % overlayWindow.count
        
        updateSelectionUI()
        guard selectedIndex < windows.count else { return }
        selectedWindow = windows[selectedIndex]
        if let w = selectedWindow {
            // bring corresponding overlay window to front
            overlayWindow[selectedIndex].orderFront(nil)
        }
        captureSelectedWindowPreview()
    }

    func navigateWindows() {
        stopNavigation()

        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            switch event.keyCode {
            case 125:
                self.moveSelection(+1)
                return nil
            case 126:
                self.moveSelection(-1)
                return nil
            case 36, 76:
                self.commitSelectionAndDismiss()
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

    // func activateWindow() {
    //     guard selectedIndex >= 0 && selectedIndex < cachedApps.count else { return }
        
    //     let app = cachedApps[selectedIndex]
    //     lastActiveAppID = app.bundleIdentifier
        
    //     app.activate(options: [.activateAllWindows])
        
    //     if let appID = lastActiveAppID,
    //        let idx = cachedApps.firstIndex(where: {$0.bundleIdentifier == appID}) {
    //         let app = cachedApps.remove(at: idx)
    //         cachedApps.insert(app, at: 0)
            
    //         selectedIndex = 0
    //         lastActiveAppID = appID
    //     }
    // }
    func activateWindow() {
        guard selectedIndex < windows.count else { return }

        let scWindow = windows[selectedIndex]

        guard
            let scApp = scWindow.owningApplication,
            let app = NSRunningApplication(processIdentifier: scApp.processID)
        else { return }

        // Bring app + all windows forward
        app.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps
        ])
    }
    
    // func commitSelectionAndDismiss() {
    //     // Dismiss overlays and previews
    //     overlayWindow.forEach { $0.orderOut(nil) }
    //     previewWindow?.orderOut(nil)
    //     systemMonitorWindow?.orderOut(nil)
    //     stopNavigation()
    //     activateWindow()
    //     // Return our app to accessory so it doesn't steal focus
    //     NSApp.setActivationPolicy(.accessory)
    // }
    func commitSelectionAndDismiss() {

        activateWindow()   // ✅ activate FIRST

        overlayWindow.forEach { $0.orderOut(nil) }
        previewWindow?.orderOut(nil)
        systemMonitorWindow?.orderOut(nil)

        stopNavigation()

        NSApp.setActivationPolicy(.accessory)
    }

    func snapshot(of window: SCWindow, completion: @escaping (NSImage?) -> Void) {
        if windowStreams[window] != nil {
            completion(nil)
            return
        }
        
        guard window.frame.width > 0 && window.frame.height > 0 else {
            completion(nil)
            return
        }

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.scalesToFit = true

        guard let filter = try? SCContentFilter(desktopIndependentWindow: window),
              let stream = try? SCStream(filter: filter, configuration: config, delegate: nil)
        else {
            completion(nil)
            return
        }

        windowStreams[window] = stream

        final class Output: NSObject, SCStreamOutput {
            let handler: (NSImage?) -> Void
            weak var delegate: AppDelegate?
            let window: SCWindow

            init(handler: @escaping (NSImage?) -> Void, delegate: AppDelegate?, window: SCWindow) {
                self.handler = handler
                self.delegate = delegate
                self.window = window
            }

            func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
                guard let pb = sampleBuffer.imageBuffer,
                      let delegate else {
                    handler(nil)
                    cleanup(stream)
                    return
                }
                
                let ciImage = CIImage(cvPixelBuffer: pb)
                guard let cg = delegate.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                    handler(nil)
                    cleanup(stream)
                    return
                }

                let img = NSImage(cgImage: cg, size: window.frame.size)
                handler(img)
                cleanup(stream)
            }

            func cleanup(_ stream: SCStream) {
                stream.stopCapture()
                Task { @MainActor in
                    self.delegate?.windowStreams.removeValue(forKey: self.window)
                    self.delegate?.streamOutputs.removeValue(forKey: self.window)
                }
            }
        }

        let output = Output(handler: completion, delegate: self, window: window)
        streamOutputs[window] = output

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
            try stream.startCapture()
        } catch {
            windowStreams.removeValue(forKey: window)
            streamOutputs.removeValue(forKey: window)
            completion(nil)
        }
    }

    func captureSelectedWindowPreview() {
        guard let win = selectedWindow else { return }
        snapshot(of: win) { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
                if let previewWindow = self.previewWindow,
                   let host = previewWindow.contentView as? NSHostingView<PreviewView> {
                    host.rootView = PreviewView(image: image)
                }
                if let previewWindow = self.previewWindow, !previewWindow.isVisible {
                    previewWindow.orderFront(nil)
                }
            }
        }
    }

    func addPreview(window: SCWindow, image: NSImage?) {
        guard let image else { return }
        windowPreviews[window] = image
    }

    func createPreviewWindow() {
        previewWindow?.close()
        previewWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        let previewSize = NSSize(width: 400, height: 300)
        
        let previewWindow = NonKeyWindow(
            index: -1,
            contentRect: NSRect(
                origin: CGPoint(
                    x: screenFrame.midX + 180,
                    y: screenFrame.midY - previewSize.height / 2
                ),
                size: previewSize
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        previewWindow.level = .floating
        previewWindow.isOpaque = false
        previewWindow.backgroundColor = .clear
        previewWindow.hasShadow = true
        previewWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        previewWindow.isReleasedWhenClosed = false
        
        previewWindow.contentView = NSHostingView(
            rootView: PreviewView(image: nil)
        )
        
        self.previewWindow = previewWindow
    }
    
    func createSystemMonitorWindow() {
        systemMonitorWindow?.close()
        systemMonitorWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        let window = OverlayWindow(
            index: -2,
            contentRect: NSRect(
                origin: CGPoint(
                    x: screenFrame.midX - monitorSize.width - 260,
                    y: screenFrame.midY - monitorSize.height / 2
                ),
                size: monitorSize
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
        window.isReleasedWhenClosed = false
        
        window.contentView = NSHostingView(
            rootView: SystemMonitorPanel()
        )
        
        systemMonitorWindow = window
    }

    struct WindowRow: View {
        var window: SCWindow
        var isSelected: Bool

        private var appName: String {
            window.owningApplication?.applicationName ?? "Unknown App"
        }
        private var windowTitle: String {
            window.title ?? ""
        }
        private var appIcon: NSImage? {
            guard
                let bundleID = window.owningApplication?.bundleIdentifier,
                let app = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID)
                    .first,
                app.activationPolicy == .regular,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else {
                return nil
            }

            return app.icon
        }

        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 34, height: 34)
                            .cornerRadius(8)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            )
                            .frame(width: 34, height: 34)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    if !windowTitle.isEmpty {
                        Text(windowTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let bundleID = window.owningApplication?.bundleIdentifier {
                        Text(bundleID)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isSelected {
                    Text("Selected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
            }
            .frame(width: 320, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.thinMaterial)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.regularMaterial)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.08)
                    )
            )
            .scaleEffect(isSelected ? 1.06 : 0.96)
            .opacity(isSelected ? 1 : 0.75)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
        }
    }
    
    struct PreviewView: View {
        var image: NSImage?
        
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.85),
                                        Color.white.opacity(0.25)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(0.35),
                        radius: 24,
                        x: 0,
                        y: 18
                    )
                
                VStack(spacing: 10) {
                    HStack {
                        Text("Live preview")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text("↩ to switch")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .padding(.horizontal, 10)
                    
                    Group {
                        if let image = image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 560, maxHeight: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(radius: 10)
                                .transition(.opacity.combined(with: .scale))
                        } else {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                
                                Text("Capturing window preview…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: 560, maxHeight: 380)
                    
                    SystemMonitorBar()
                }
                .padding(14)
            }
            .frame(width: 600, height: 400)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: image != nil)
        }
    }
}
