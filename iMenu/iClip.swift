import SwiftUI
import CoreData
import AppKit
import Combine

@MainActor

class iClip: NSObject, NSApplicationDelegate {
    final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
    
    final class ClipboardStore: ObservableObject {
        @Published var history: [String] = []
        @Published var selectedIndex: Int = 0
        
        private var lastChange = NSPasteboard.general.changeCount
        private var timer: Timer?
        
        init() {
            start()
        }
        
        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let self else { return }
                let pb = NSPasteboard.general
                
                if pb.changeCount != lastChange {
                    self.lastChange = pb.changeCount
                    
                    if let str = pb.string(forType: .string) {
                        DispatchQueue.main.async {
                            if let existingIndex = self.history.firstIndex(of: str) {
                                self.history.remove(at: existingIndex)
                                self.history.insert(str, at: 0)
                            } else {
                                self.history.insert(str, at: 0)
                            }
                        }
                    }
                }
            }
        }
    }
    
    var overlayWindow: NSWindow?
    
    var wasHotKeyPressed: Bool = false
    
    var globalMonitor: Any?
    var localMonitor: Any?
    var navigationMonitor: Any?
    
    var selectedIndex: Int = 0
    
    let clipboardStore = ClipboardStore()
    
    func createOverlay() {
        overlayWindow?.close()
        overlayWindow = nil
        
        let windowSize = NSSize(width: 360, height: 420)
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        let window = OverlayWindow(
            contentRect: NSRect(
                origin: CGPoint(
                    x: screenFrame.midX - windowSize.width / 2,
                    y: screenFrame.midY - windowSize.height / 2
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
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        
        window.contentView = NSHostingView(
            rootView: CombinedSearchView(
                store: clipboardStore
            )
        )
        
        window.makeKeyAndOrderFront(nil)
        overlayWindow = window
    }
    
    func toggleOverlay() {
        if self.overlayWindow?.isVisible == true {
            overlayWindow?.orderOut(nil)
            stopNavigation()
            return
        }
        
        createOverlay()
        NSApp.activate(ignoringOtherApps: true)
        
        startNavigation()
    }
    
    func startNavigation() {
        stopNavigation()
        
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown){ [weak self] event in
            guard let self else { return event }
            
            switch event.keyCode {
            case 125:
                self.moveSelection(+1)
                return nil
                
            case 126:
                self.moveSelection(-1)
                return nil
                
            default:
                return event
            }
        }
    }
    
    func moveSelection(_ delta: Int) {
        let count = clipboardStore.history.count
        
        guard count > 0 else { return }
        
        clipboardStore.selectedIndex = (clipboardStore.selectedIndex + delta + count) % count
    }
    
    func stopNavigation() {
        if let monitor = navigationMonitor {
            NSEvent.removeMonitor(monitor)
            navigationMonitor = nil
        }
    }
    
    struct CombinedSearchView: View {
        @State private var query = ""
        @FocusState private var isFocused: Bool
        @ObservedObject var store: ClipboardStore
        
        var filterData: [String] {
            query.isEmpty ? store.history : store.history.filter{ $0.localizedCaseInsensitiveContains(query)}
        }
        
        var body: some View {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    
                    TextField("Search in clipboard history...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused($isFocused)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                )
                .onAppear {
                    DispatchQueue.main.async {
                        isFocused = true
                    }
                }
                
                VStack(spacing: 0) {
                    ForEach(Array(filterData.enumerated()), id: \.offset) { index, item in
                        HStack{
                            Text(item)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            
                            Spacer()
                            
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(item, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            index == store.selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear
                        )
                        
                        Divider().opacity(0.15)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(14)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}
