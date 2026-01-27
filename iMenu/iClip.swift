import SwiftUI
import CoreData
import AppKit
import Combine

@MainActor

class iClip: NSObject, NSApplicationDelegate {
    
    static let shared = iClip()
    private override init() {
        super.init()
    }
    
    
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
        
        func deleteHistory(_ item : String) {
            history.removeAll{ $0 == item }
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
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        startNavigation()
    }
    
    func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isHotkeyPressed = flags.contains(.control) && flags.contains(.option)
        
        if isHotkeyPressed && !wasHotKeyPressed {
            toggleOverlay()
        }
        
        wasHotKeyPressed = isHotkeyPressed
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

        var filteredData: [String] {
            query.isEmpty
            ? store.history
            : store.history.filter {
                $0.localizedCaseInsensitiveContains(query)
            }
        }

        var body: some View {
            VStack(spacing: 12) {

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search in clipboard history...", text: $query)
                        .textFieldStyle(.plain)
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

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredData.enumerated()), id: \.offset) { index, item in
                                ClipboardRow(
                                    item: item,
                                    isSelected: index == store.selectedIndex,
                                    
                                    onCopy: {
                                        let pb = NSPasteboard.general
                                        pb.clearContents()
                                        pb.setString(item, forType: .string)
                                    },
                                    onDelete: {
                                        store.deleteHistory(item)
                                    },
                                    onSelect: {
                                        store.selectedIndex = index
                                    },
                                )
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: store.selectedIndex) { _ in
                        withAnimation {
                            proxy.scrollTo(store.selectedIndex, anchor: .center)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
        }
    }

        
    struct ClipboardRow: View {
            
        let item: String
        let isSelected: Bool
        let onCopy: () -> Void
        let onDelete: () -> Void
        let onSelect: () -> Void
        var body: some View {
            HStack{
                Text(item)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    
                Spacer()
                    
                Button(action: onCopy){
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                    
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .background(
                isSelected ? Color.accentColor.opacity(0.2) : Color.clear
            )
                
            Divider().opacity(0.15)
        }
    }
}

