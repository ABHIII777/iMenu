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
        HStack(spacing: 12) {
            MetricPill(label: "MEM", value: snapshot.memoryUsedPercent.map { "\($0)%" } ?? "–")
            MetricPill(label: "DSK", value: snapshot.diskUsedPercent.map { "\($0)%" } ?? "–")
            MetricPill(label: "BAT", value: snapshot.batteryPercent.map { "\($0)%" } ?? "–")
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
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
                    .foregroundStyle(.quaternary)
                    .kerning(0.3)
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SystemMonitorPanel: View {
    @State private var snapshot = SystemSnapshot.current()
    @State private var memoryHistory: [Int] = []
    private let maxHistoryCount = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("System")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Date(), style: .time)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().opacity(0.15)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                    Spacer()
                    if let mem = snapshot.memoryUsedPercent {
                        Text("\(mem)%")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(memoryColor(mem))
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in
                                Divider().opacity(0.07)
                                Spacer()
                            }
                        }

                        if memoryHistory.count >= 2 {
                            let values = memoryHistory

                            Path { path in
                                for (i, v) in values.enumerated() {
                                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                                    let y = geo.size.height * (1 - CGFloat(v) / 100)
                                    i == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y))
                                }
                                path.addLine(to: .init(x: geo.size.width, y: geo.size.height))
                                path.addLine(to: .init(x: 0, y: geo.size.height))
                                path.closeSubpath()
                            }
                            .fill(LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), .clear],
                                startPoint: .top, endPoint: .bottom
                            ))

                            Path { path in
                                for (i, v) in values.enumerated() {
                                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                                    let y = geo.size.height * (1 - CGFloat(v) / 100)
                                    i == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y))
                                }
                            }
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

                        } else {
                            Text("Collecting…")
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.15)

            HStack(spacing: 0) {
                MetricTile(
                    label: "Storage",
                    icon: "internaldrive",
                    value: snapshot.diskUsedPercent.map { "\($0)%" } ?? "–",
                    tint: storageColor(snapshot.diskUsedPercent ?? 0)
                )
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 10)
                MetricTile(
                    label: "Battery",
                    icon: "bolt",
                    value: snapshot.batteryPercent.map { "\($0)%" } ?? "–",
                    tint: batteryColor(snapshot.batteryPercent ?? 100)
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
        .frame(width: 220)
        .onAppear {
            updateSnapshot()
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in updateSnapshot() }
        }
    }

    private func updateSnapshot() {
        let s = SystemSnapshot.current()
        snapshot = s
        if let mem = s.memoryUsedPercent {
            memoryHistory.append(mem)
            if memoryHistory.count > maxHistoryCount {
                memoryHistory.removeFirst(memoryHistory.count - maxHistoryCount)
            }
        }
    }

    private func memoryColor(_ v: Int) -> Color  { v > 85 ? .red : v > 65 ? .orange : .primary }
    private func storageColor(_ v: Int) -> Color { v > 90 ? .red : v > 75 ? .orange : Color.accentColor }
    private func batteryColor(_ v: Int) -> Color { v < 15 ? .red : v < 30 ? .orange : Color.accentColor }

    private struct MetricTile: View {
        let label: String
        let icon: String
        let value: String
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tint)
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .kerning(0.4)
                }
                Text(value)
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}
