import SwiftUI
import AppKit
import CoreGraphics
import Cocoa
import ScreenCaptureKit
import Darwin

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
    
    struct AppEntry {
        let app: SCRunningApplication
        let representativeWindow: SCWindow
    }
    
    var overlayWindow: [NSWindow] = []
    var previewWindow: NSWindow?
    var selectedIndex: Int = 0
    
    var apps: [AppEntry] = []
    var selectedApp: AppEntry?
    
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
    
    let ciContext = CIContext()
    
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences",
    ]
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

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
        let isCmdOptionPressed      = flags.contains(.command) && flags.contains(.option)
        let isControlOptionPressed  = flags.contains(.control) && flags.contains(.option)
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

        wasCmdShiftPressed      = isCmdOptionPressed
        wasControlOptionPressed = isControlOptionPressed
        wasCommandControlPressed = isCommandControlPressed
    }
    
    func ensureAuthorization(completion: @escaping (Bool) -> Void) {
        if CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.async { completion(true) }
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
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return Set(list.compactMap { info -> CGWindowID? in
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0
            else { return nil }

            guard
                let alpha = info[kCGWindowAlpha as String] as? Double,
                alpha > 0.1
            else { return nil }

            guard
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"],
                let height = bounds["Height"],
                width > 100,
                height > 100
            else { return nil }

            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }
    
    func refreshWindowsAndOverlay() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self, let content else { return }

            var windows: [SCWindow] = []

            for w in content.windows {
                guard 
                    let scApp = w.owningApplication,
                    let nsApp = NSRunningApplication(processIdentifier: scApp.processID),
                    nsApp.activationPolicy == .regular,
                    !nsApp.isHidden,
                    !scApp.applicationName.isEmpty,
                    w.frame.width > 120,
                    w.frame.height > 120,
                    !(nsApp.bundleIdentifier.map {Self.excludedBundleIDs.contains($0)} ?? false)
                else { continue }

                windows.append(w)
            }

            let entries = windows.map {
                AppEntry(app: $0.owningApplication!, representativeWindow: $0)
            }

            Task { @MainActor in
                self.apps = entries
                self.selectedIndex = 0
                self.buildOverlay(from: entries)
                self.selectedApp = entries.first
                self.captureSelectedWindowPreview()
                self.previewWindow?.orderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.navigateWindows()
            }
        }
    }
    
    func buildOverlay(from entries: [AppEntry]) {
        overlayWindow.forEach { $0.close() }
        overlayWindow.removeAll()
        previewWindow?.close(); previewWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize  = NSSize(width: 320, height: 115)
        let spacing: CGFloat = 82
        let totalHeight = CGFloat(entries.count) * spacing
        let startY = screenFrame.midY + (totalHeight / 2) - (spacing / 2)
        
        for (index, entry) in entries.enumerated() {
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
                rootView: AppRow(entry: entry, isSelected: index == selectedIndex)
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
        let selectedFrame  = selectedWindow.frame
        let previewSize    = previewWindow.frame.size
        
        let newOrigin = CGPoint(
            x: selectedFrame.maxX + 20,
            y: selectedFrame.midY - previewSize.height / 2
        )
        previewWindow.setFrameOrigin(newOrigin)
    }
    
    func updateSelectionUI() {
        for (index, window) in overlayWindow.enumerated() {
            if let host = window.contentView as? NSHostingView<AppRow> {
                let old = host.rootView
                host.rootView = AppRow(entry: old.entry, isSelected: index == selectedIndex)
            }
        }
        updatePreviewPosition()
    }
    
    func moveSelection(_ delta: Int) {
        guard !overlayWindow.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + overlayWindow.count) % overlayWindow.count
        
        updateSelectionUI()
        guard selectedIndex < apps.count else { return }
        selectedApp = apps[selectedIndex]
        if selectedApp != nil {
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

    func findMatchingAXWindow(for scWindow: SCWindow) -> AXUIElement? {
        let pid = scWindow.owningApplication!.processID
        let axApp = AXUIElementCreateApplication(pid)

        var value: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            axApp,
            kAXWindowsAttribute as CFString,
            &value
        )

        guard result == .success,
            let axWindows = value as? [AXUIElement]
        else {
            return nil
        }

        for axWindow in axWindows {
            var windowID: CGWindowID = 0

            let err = _AXUIElementGetWindow(axWindow, &windowID)

            if err == .success {
                if windowID == scWindow.windowID {
                    return axWindow
                }
            }
        }

        return nil
    }
    
    func activateApp() {
        guard selectedIndex < apps.count else { return }
        let entry = apps[selectedIndex]

        guard let nsApp = NSRunningApplication(processIdentifier: entry.app.processID) else { return }

        nsApp.activate(options: [.activateIgnoringOtherApps])

        if let axWindow = findMatchingAXWindow(for: entry.representativeWindow) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func commitSelectionAndDismiss() {
        activateApp()
        
        overlayWindow.forEach { $0.orderOut(nil) }
        previewWindow?.orderOut(nil)
        stopNavigation()
        NSApp.setActivationPolicy(.accessory)
    }
    
    
    func snapshot(of window: SCWindow, completion: @escaping (NSImage?) -> Void) {
        let w = window.frame.width, h = window.frame.height
        guard w > 0, h > 0 else { completion(nil); return }

        let scale  = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = min(Int(w * scale), 3840)
        let pixelH = min(Int(h * scale), 2160)

        let config = SCStreamConfiguration()
        config.width       = pixelW
        config.height      = pixelH
        config.scalesToFit = true
        config.showsCursor = false

        guard let filter = try? SCContentFilter(desktopIndependentWindow: window) else {
            completion(nil); return
        }

        Task {
            do {
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                let image = NSImage(cgImage: cgImage, size: window.frame.size)
                await MainActor.run { completion(image) }
            } catch {
                print("[snapshot] failed for \(window.title ?? "?"): \(error)")
                await MainActor.run { completion(nil) }
            }
        }
    }

    func captureSelectedWindowPreview() {
        guard let entry = selectedApp else { return }
        snapshot(of: entry.representativeWindow) { [weak self] image in
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
    
    func createPreviewWindow() {
        previewWindow?.close()
        previewWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let previewSize = NSSize(width: 400, height: 300)
        
        let win = NonKeyWindow(
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
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: PreviewView(image: nil))
        self.previewWindow = win
    }
    
    struct AppRow: View {
        var entry: AppEntry
        var isSelected: Bool
        
        private var appName: String { entry.app.applicationName }
        
        private var appIcon: NSImage? {
            let bundleID = entry.app.bundleIdentifier
            guard !bundleID.isEmpty,
                bundleID != Bundle.main.bundleIdentifier,
                let nsApp = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID)
                    .first(where: { $0.icon != nil && $0.activationPolicy == .regular })
            else { return nil }
            return nsApp.icon
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
                            .frame(width: 34, height: 34)
                            .cornerRadius(8)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 34, height: 34)
                            .overlay(
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                
                Text(appName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                
                Spacer()
            }
            .frame(width: 300, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
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
                    .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 10)
                
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
