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
    
    struct ClipboardItem: Identifiable, Equatable {
        let id = UUID()
        let content: String
        let createdAt: Date
    }
    
    final class ClipboardStore: ObservableObject {
        @Published var history: [ClipboardItem] = []
        @Published var selectedIndex: Int = 0
        
        private var lastChange = NSPasteboard.general.changeCount
        private var timer: Timer?
        
        let retentionDays: TimeInterval = 3 * 24 * 60 * 60
        
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
                            let now = Date()
                            
                            if let existingIndex = self.history.firstIndex(where: { $0.content == str }) {
                                self.history.remove(at: existingIndex)
                            }
                            
                            self.history.insert(
                                ClipboardItem(content: str, createdAt: now),
                                at: 0
                            )
                            
                            self.removeExpiredItems()
                        }
                    }
                }
            }
        }
        
        func deleteHistory(_ item : ClipboardItem) {
            history.removeAll{ $0.id == item.id }
        }
        
        func clearAllHistory() {
            history.removeAll()
            selectedIndex = 0
        }
        
        func removeExpiredItems() {
            let now = Date()
            history.removeAll {
                now >= $0.createdAt.addingTimeInterval(retentionDays)
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
    
        var filteredData: [ClipboardItem] {
            query.isEmpty
            ? store.history
            : store.history.filter {
                $0.content.localizedCaseInsensitiveContains(query)
            }
        }
    
        var body: some View {
            VStack(spacing: 14) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "scissors")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        
                        Text("iClip")
                            .font(.system(size: 14, weight: .semibold))
                        
                        if !store.history.isEmpty {
                            Text("· \(store.history.count) items")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if !store.history.isEmpty {
                        Button {
                            store.clearAllHistory()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear Clipboard History")
                    }
                    
                    Text("⌃⌥ to toggle · ↑ ↓ to navigate")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    
                    TextField("Search clipboard…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .onAppear {
                    DispatchQueue.main.async {
                        isFocused = true
                    }
                }
    
                // List
                ScrollViewReader { proxy in
                    Group {
                        if filteredData.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "rectangle.and.text.magnifyingglass")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                                Text("No clipboard items yet")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Copy something and it will appear here automatically.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(filteredData.indices, id: \.self) { index in
                                        let item = filteredData[index]
                                        
                                        ClipboardRow(
                                            item: item.content,
                                            isSelected: index == store.selectedIndex,
                                            onCopy: {
                                                let pb = NSPasteboard.general
                                                pb.clearContents()
                                                pb.setString(item.content, forType: .string)
                                            },
                                            onDelete: {
                                                store.deleteHistory(item)
                                            },
                                            onSelect: {
                                                store.selectedIndex = index
                                            }
                                        )
                                        .id(index)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: store.selectedIndex) { _ in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            proxy.scrollTo(store.selectedIndex, anchor: .center)
                        }
                    }
                }
                
                SystemMonitorBar()
            }
            .padding(16)
            .frame(width: 380, height: 420)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 18)
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
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                    
                    Spacer(minLength: 8)
                }
                
                HStack(spacing: 10) {
                    Text("Press ⌘V in your app after pasting")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                        ? Color.accentColor.opacity(0.22)
                        : Color.clear
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected
                                ? Color.accentColor.opacity(0.7)
                                : Color.white.opacity(0.06),
                                lineWidth: isSelected ? 1.4 : 1
                            )
                    )
            )
            .onTapGesture(perform: onSelect)
        }
    }
}
