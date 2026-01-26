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
    var previewWindow: NSWindow?
    var cachedApps: [NSRunningApplication] = []
    var selectedIndex: Int = 0

    var globalEventMonitor: Any?
    var localEventMonitor: Any?
    var navigationMonitor: Any?

    var wasCmdShiftPressed = false
    var wasControlOptionPressed = false

    var windowStreams: [SCWindow: SCStream] = [:]
    var streamOutputs: [SCWindow: AnyObject] = [:]

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
                self.stopNavigation()
                return
            }

            self.createOverlay()
            self.overlayWindow.forEach { $0.makeKeyAndOrderFront(nil) }
            self.previewWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.navigateWindows()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.captureWindow()
            }
        }
    }


    func createOverlay() {
        cachedApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !$0.isHidden
        }

        guard !cachedApps.isEmpty, let screen = NSScreen.main else { return }

        overlayWindow.forEach { $0.close() }
        overlayWindow.removeAll()
        previewWindow?.close()
        previewWindow = nil
        selectedIndex = 0

        let windowSize = NSSize(width: 320, height: 100)
        let screenFrame = screen.visibleFrame

        let spacing: CGFloat = 80
        let totalHeight = CGFloat(cachedApps.count) * spacing
        let startY = screenFrame.midY + (totalHeight / 2) - (spacing / 2)

        for (index, app) in cachedApps.enumerated() {
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
                rootView: RunningApps(app: app, isSelected: index == selectedIndex, preview: nil)
            )
            overlayWindow.append(window)
        }
        
        createPreviewWindow()
    }
    
    func createPreviewWindow() {
        previewWindow?.close()
        previewWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        let previewSize = NSSize(width: 400, height: 300)
        
        let previewWindow = OverlayWindow(
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
    
    func updatePreviewPosition() {
        guard let previewWindow = previewWindow,
              let screen = NSScreen.main,
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
            guard let host = window.contentView as? NSHostingView<RunningApps> else { continue }
            let old = host.rootView
            NSAnimationContext.runAnimationGroup{ _ in
                host.rootView = RunningApps(
                    app: old.app,
                    isSelected: index == selectedIndex,
                    preview: nil
                )
            }
        }
        
        updatePreviewPosition()
    }

    func moveSelection(_ delta: Int) {
        guard !overlayWindow.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + overlayWindow.count) % overlayWindow.count
        
        updateSelectionUI()
        
        guard selectedIndex < overlayWindow.count else { return }
        overlayWindow[selectedIndex].makeKey()
        
        updatePreviewPosition()
        
        if let previewWindow = previewWindow,
           let host = previewWindow.contentView as? NSHostingView<PreviewView> {
            host.rootView = PreviewView(image: nil)
        }
        captureWindow()
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
                self.overlayWindow.forEach { $0.orderOut(nil) }
                self.previewWindow?.orderOut(nil)
                self.stopNavigation()
                self.activateWindow()
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
        guard selectedIndex >= 0 && selectedIndex < cachedApps.count else { return }
        cachedApps[selectedIndex].activate(options: [.activateAllWindows])
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

    func captureWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            
            let apps = self.cachedApps
            let selectedIdx = self.selectedIndex

            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
                let scWindows = content?.windows ?? []

                Task { @MainActor in
                    guard selectedIdx < apps.count && selectedIdx < self.overlayWindow.count else { return }
                    
                    let app = apps[selectedIdx]
                    
                    let candidates = scWindows.filter {
                        $0.owningApplication?.bundleIdentifier == app.bundleIdentifier &&
                        $0.frame.width > 50 &&
                        $0.frame.height > 50
                    }

                    guard let best = candidates.max(by: {
                        ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
                    }) else {
                        return
                    }

                        self.snapshot(of: best) { image in
                            Task { @MainActor in
                                if let previewWindow = self.previewWindow,
                                   let host = previewWindow.contentView as? NSHostingView<PreviewView> {
                                    host.rootView = PreviewView(image: image)
                                }
                                
                                if let previewWindow = self.previewWindow, !previewWindow.isVisible {
                                    previewWindow.makeKeyAndOrderFront(nil)
                                }
                            }
                        }
                }
            }
        }
    }

    struct RunningApps: View {
        var app: NSRunningApplication
        var isSelected: Bool
        var preview: NSImage?

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
            .frame(width: 320)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.gray.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? .white : .clear, lineWidth: 3)
                    )
            )
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .shadow(radius: isSelected ? 20 : 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
    }
    
    struct PreviewView: View {
        var image: NSImage?
        
        var body: some View {
            Group {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 600, maxHeight: 400)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(.white, lineWidth: 3)
                                )
                        )
                        .transition(.opacity.combined(with: .scale))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.accentColor.opacity(0.15), lineWidth: 2)
                        )
                        .frame(width: 600, height: 400)
                        .padding(10)
                        .overlay(
                            ProgressView()
                                .scaleEffect(1.5)
                        )
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: image != nil)
        }
    }
}
