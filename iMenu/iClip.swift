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
        @Published var selectedINdex: Int = 0
        
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
                            index == store.selectedINdex ? Color.accentColor.opacity(0.2) : Color.clear
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
    
    struct SearchWindow: View {
        
        @Binding var query: String
        @FocusState private var isFocused: Bool
        
        var body: some View {
            
        }
    }
    
    struct SearchResult: View {
        
        let items: [String]
        
        var body: some View {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 0)
                                    .fill(.ultraThinMaterial)
                                    .border(Color.accentColor, width: 0.5)
                                    .cornerRadius(8)
                            )
                            .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
    }
}
