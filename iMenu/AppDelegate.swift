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
    var wasCommandControlPressed = false

    var isClipboardOverlayVisible = false

    var standAloneMonitorWindow: NSWindow?
    
    var windowStreams: [SCWindow: SCStream] = [:]
    var streamOutputs: [SCWindow: AnyObject] = [:]
    
    private static let disallowedBundleIDPrefixes: Set<String> = [
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
    ]
    
    let ciContext = CIContext()
    
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
        let isCmdOptionPressed     = flags.contains(.command) && flags.contains(.option)
        let isControlOptionPressed = flags.contains(.control) && flags.contains(.option)
        let isCommandControlPressed = flags.contains(.command) && flags.contains(.control)
            && !flags.contains(.option)

        if isCmdOptionPressed && !wasCmdShiftPressed {
            if isClipboardOverlayVisible {
                iClip.shared.toggleOverlay()
                isClipboardOverlayVisible = false
            }
            toggleOverlay()
        }

        if isControlOptionPressed && !wasControlOptionPressed {
            if overlayWindow.contains(where: { $0.isVisible }) {
                overlayWindow.forEach { $0.orderOut(nil) }
                previewWindow?.orderOut(nil)
                stopNavigation()
                NSApp.setActivationPolicy(.accessory)
            }
            iClip.shared.toggleOverlay()
            isClipboardOverlayVisible.toggle() 
        }

        if isCommandControlPressed && !wasCommandControlPressed {
            toggleStandaloneMonitor()
        }

        wasCmdShiftPressed = isCmdOptionPressed
        wasControlOptionPressed = isControlOptionPressed
        wasCommandControlPressed = isCommandControlPressed
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
                self.stopNavigation()
                NSApp.setActivationPolicy(.accessory)
                return
            }
            
            self.refreshWindowsAndOverlay()
        }
    }
    func toggleStandaloneMonitor() {
        if let existing = standAloneMonitorWindow, existing.isVisible {
            existing.orderOut(nil)
            return
        }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = NSSize(width: 220, height: 260)

        if standAloneMonitorWindow == nil {
            let win = OverlayWindow(
                index: -3,
                contentRect: NSRect(
                    origin: CGPoint(
                        x: screenFrame.maxX - size.width - 20,
                        y: screenFrame.maxY - size.height - 20
                    ),
                    size: size
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .floating
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: SystemMonitorPanel())
            standAloneMonitorWindow = win
        } else {
            standAloneMonitorWindow?.setFrameOrigin(CGPoint(
                x: screenFrame.maxX - size.width - 20,
                y: screenFrame.maxY - size.height - 20
            ))
        }

        NSApp.activate(ignoringOtherApps: true)
        standAloneMonitorWindow?.orderFront(nil)
    }

    private func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return Set(list.compactMap { info -> CGWindowID? in 
            guard 
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0
            else { return nil }

            return info[kCGWindowNumber as String] as? CGWindowID
         })
    }
    
    func refreshWindowsAndOverlay() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self, let content else { return }

            let validIDs = self.onScreenWindowIDs()
            
            let filtered: [SCWindow] = content.windows.compactMap { w in
                guard
                    let scApp = w.owningApplication,
                    let nsApp = NSRunningApplication(processIdentifier: scApp.processID),
                    nsApp.activationPolicy == .regular,
                    !nsApp.isHidden,
                    w.frame.width > 50,
                    w.frame.height > 50,
                    validIDs.contains(w.windowID)
                else { return nil }
                
                guard NSScreen.screens.contains(where: {
                    !NSIntersectionRect($0.visibleFrame, w.frame).isEmpty
                }) else { return nil }
                
                if let bundleID = nsApp.bundleIdentifier,
                   Self.disallowedBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                    return nil
                }
                
                guard !(w.title?.isEmpty ?? true) || !(scApp.applicationName.isEmpty) else {
                    return nil
                }
                
                return w
            }
            
            let sorted = filtered.sorted {
                let aName = $0.owningApplication?.applicationName ?? ""
                let bName = $1.owningApplication?.applicationName ?? ""
                if aName != bName { return aName < bName }
                return $0.frame.origin.y > $1.frame.origin.y
            }
            
            Task { @MainActor in
                self.windows = sorted
                self.selectedIndex = 0
                self.buildOverlay(from: sorted)
                self.selectedWindow = sorted.first
                self.captureSelectedWindowPreview()
                self.previewWindow?.orderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.navigateWindows()
            }
        }
    }
    
    func buildOverlay(from windows: [SCWindow]) {
        overlayWindow.forEach { $0.close() }
        overlayWindow.removeAll()
        previewWindow?.close(); previewWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = NSSize(width: 320, height: 100)
        let spacing: CGFloat = 70
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
    
    func updateSelectionUI() {
        for (index, window) in overlayWindow.enumerated() {
            if let host = window.contentView as? NSHostingView<WindowRow> {
                let old = host.rootView
                host.rootView = WindowRow(window: old.window, isSelected: index == selectedIndex)
            }
        }
        
        updatePreviewPosition()
    }
    
    func moveSelection(_ delta: Int) {
        guard !overlayWindow.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + overlayWindow.count) % overlayWindow.count
        
        updateSelectionUI()
        guard selectedIndex < windows.count else { return }
        selectedWindow = windows[selectedIndex]
        if let w = selectedWindow {
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
    
    func commitSelectionAndDismiss() {
        
        activateWindow()
        
        overlayWindow.forEach { $0.orderOut(nil) }
        previewWindow?.orderOut(nil)
        
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
                    .first(where: { $0.icon != nil }),
                app.activationPolicy == .regular,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else {
                return nil
            }
            return app.icon
        }
        
        var body: some View {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 3, height: 28)
                    .animation(.easeOut(duration: 0.15), value: isSelected)
                
                Group {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .cornerRadius(7)
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.quaternary)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(appName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    
                    if !windowTitle.isEmpty {
                        Text(windowTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            .frame(width: 300, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? .regularMaterial : .thinMaterial)
            )
            .opacity(isSelected ? 1 : 0.7)
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        
    }

    struct PreviewView: View {
        var image: NSImage?
        
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(
                        color: Color.black.opacity(0.18),
                        radius: 16,
                        x: 0,
                        y: 10
                    )
                
                VStack(spacing: 8) {
                    HStack {
                        Text("Preview")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .kerning(0.5)
                        
                        Spacer()
                        
                        Text("↩ switch")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 12)
                    
                    Group {
                        if let image = image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 560, maxHeight: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .transition(.opacity)
                        } else {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Loading…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: 560, maxHeight: 380)
                }
                .padding(12)
            }
            .frame(width: 580, height: 390)
            .animation(.easeOut(duration: 0.2), value: image != nil)
        }
    }
}
