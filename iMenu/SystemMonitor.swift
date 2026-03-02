import SwiftUI
import Foundation
import Darwin
import IOKit.ps

struct SystemSnapshot {
    let diskUsedPercent: Int?
    let memoryUsedPercent: Int?
    let batteryPercent: Int?
    
    static func current() -> SystemSnapshot {
        let disk = currentDiskUsagePercent()
        let memory = currentMemoryUsagePercent()
        let battery = currentBatteryPercent()
        
        return SystemSnapshot(
            diskUsedPercent: disk,
            memoryUsedPercent: memory,
            batteryPercent: battery
        )
    }
}

private func currentDiskUsagePercent() -> Int? {
    do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
        guard
            let total = attrs[.systemSize] as? NSNumber,
            let free = attrs[.systemFreeSize] as? NSNumber
        else { return nil }
        
        let totalBytes = total.doubleValue
        let freeBytes = free.doubleValue
        guard totalBytes > 0 else { return nil }
        
        let usedBytes = totalBytes - freeBytes
        let percent = Int((usedBytes / totalBytes) * 100.0)
        return max(0, min(100, percent))
    } catch {
        return nil
    }
}

private func currentMemoryUsagePercent() -> Int? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
    
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    
    guard result == KERN_SUCCESS else { return nil }
    
    let pageSize = Double(vm_kernel_page_size)
    let active = Double(stats.active_count + stats.inactive_count + stats.wire_count) * pageSize
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    guard total > 0 else { return nil }
    
    let percent = Int((active / total) * 100.0)
    return max(0, min(100, percent))
}

private func currentBatteryPercent() -> Int? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
    guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    
    for ps in list {
        guard
            let description = IOPSGetPowerSourceDescription(snapshot, ps)?
                .takeUnretainedValue() as? [String: Any]
        else { continue }
        
        if let capacity = description[kIOPSCurrentCapacityKey as String] as? Int,
           let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
           maxCapacity > 0 {
            let percent = Int((Double(capacity) / Double(maxCapacity)) * 100.0)
            return Swift.max(0, Swift.min(100, percent))
        }
    }
    
    return nil
}

struct SystemMonitorBar: View {
    @State private var snapshot = SystemSnapshot.current()
    
    var body: some View {
        HStack(spacing: 8) {
            MetricPill(
                label: "Storage",
                value: snapshot.diskUsedPercent.map { "\($0)%" } ?? "–"
            )
            
            MetricPill(
                label: "Memory",
                value: snapshot.memoryUsedPercent.map { "\($0)%" } ?? "–"
            )
            
            MetricPill(
                label: "Battery",
                value: snapshot.batteryPercent.map { "\($0)%" } ?? "–"
            )
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                snapshot = SystemSnapshot.current()
            }
        }
    }
    
    private struct MetricPill: View {
        let label: String
        let value: String
        
        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}

struct SystemMonitorPanel: View {
    @State private var snapshot = SystemSnapshot.current()
    @State private var memoryHistory: [Int] = []
    
    private let maxHistoryCount = 60
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "gauge.medium")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                
                Text("System monitor")
                    .font(.system(size: 13, weight: .semibold))
                
                Spacer()
                
                Text(Date(), style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            
            // Memory usage graph
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Memory")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if let mem = snapshot.memoryUsedPercent {
                        Text("\(mem)% used")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                        
                        if memoryHistory.count >= 2 {
                            let values = memoryHistory
                            let maxVal = max(100, values.max() ?? 100)
                            let minVal = min(0, values.min() ?? 0)
                            let span = max(1, maxVal - minVal)
                            
                            Path { path in
                                for (idx, value) in values.enumerated() {
                                    let x = geo.size.width * CGFloat(idx) / CGFloat(max(values.count - 1, 1))
                                    let normalized = CGFloat(value - minVal) / CGFloat(span)
                                    let y = geo.size.height * (1 - normalized)
                                    
                                    if idx == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                            }
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor,
                                        Color.accentColor.opacity(0.4)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)
                            )
                            
                            // Subtle fill under the line
                            Path { path in
                                for (idx, value) in values.enumerated() {
                                    let x = geo.size.width * CGFloat(idx) / CGFloat(max(values.count - 1, 1))
                                    let normalized = CGFloat(value - minVal) / CGFloat(span)
                                    let y = geo.size.height * (1 - normalized)
                                    
                                    if idx == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                                path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.28),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        } else {
                            Text("Collecting memory data…")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 70)
            }
            
            // Other metrics
            HStack(spacing: 8) {
                MetricTile(
                    title: "Storage",
                    systemImage: "internaldrive",
                    value: snapshot.diskUsedPercent.map { "\($0)%" } ?? "–"
                )
                
                MetricTile(
                    title: "Battery",
                    systemImage: "battery.100",
                    value: snapshot.batteryPercent.map { "\($0)%" } ?? "–"
                )
            }
        }
        .padding(12)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 20, x: 0, y: 14)
        )
        .onAppear {
            updateSnapshot()
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                updateSnapshot()
            }
        }
    }
    
    private func updateSnapshot() {
        let newSnapshot = SystemSnapshot.current()
        snapshot = newSnapshot
        
        if let mem = newSnapshot.memoryUsedPercent {
            memoryHistory.append(mem)
            if memoryHistory.count > maxHistoryCount {
                memoryHistory.removeFirst(memoryHistory.count - maxHistoryCount)
            }
        }
    }
    
    private struct MetricTile: View {
        let title: String
        let systemImage: String
        let value: String
        
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
    }
}
