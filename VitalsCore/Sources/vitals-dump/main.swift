import Foundation
import MetricsEngine
import SystemMetrics

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
}

// MARK: - Hardware inventory

print("=== Hardware ===")

guard let profile = try? HardwareProfile.detect() else {
    print("Failed to detect hardware.")
    exit(1)
}

print("CPU:          \(profile.cpu.brand)")
// Core counts are `Int?`: an absent sysctl prints as unavailable, never as 0.
let physical = profile.cpu.physicalCores.map(String.init) ?? "unavailable"
let logical = profile.cpu.logicalCores.map(String.init) ?? "unavailable"
print("Cores:        \(physical) physical, \(logical) logical")
for cluster in profile.cpu.clusters {
    print("  \(cluster.name): \(cluster.coreCount) cores")
}
print("L2 cache:     \(profile.cpu.l2CacheBytes.map(UInt64.init).map(formatBytes) ?? "unavailable")")
print("L3 cache:     \(profile.cpu.l3CacheBytes.map(UInt64.init).map(formatBytes) ?? "unavailable")")

print("")
print("Memory:       \(formatBytes(profile.memory.totalBytes)) \(profile.memory.type ?? "unknown type")")
print("Manufacturer: \(profile.memory.manufacturer ?? "unknown")")
print("Unified:      \(profile.memory.isUnified ? "yes" : "no")")

if let speed = profile.memory.speedMHz {
    print("Speed:        \(speed) MHz")
} else if let bandwidth = profile.memory.peakBandwidthGBs {
    print("Bandwidth:    \(bandwidth) GB/s (SoC specification)")
} else {
    print("Speed:        not reported by this hardware")
}

for slot in profile.memory.slots {
    print("  \(slot.name): \(slot.sizeDescription) \(slot.type ?? "") \(slot.speedMHz.map { "\($0) MHz" } ?? "")")
}

print("")
for gpu in profile.gpus {
    print("GPU:          \(gpu.name)")
    switch gpu.topology {
    case .unified(let bytes):
        print("  Memory:     \(formatBytes(bytes)) unified")
    case .dedicated(let bytes):
        print("  Memory:     \(formatBytes(bytes)) dedicated VRAM")
    case .shared(let bytes):
        print("  Memory:     \(formatBytes(bytes)) shared with system")
    }
}

print("")
let systemLoad = SystemLoad.current()
let uptimeHours = Int(systemLoad.uptimeSeconds / 3600)
print("Uptime:       \(uptimeHours)h")

let averages = [systemLoad.loadAverage1, systemLoad.loadAverage5, systemLoad.loadAverage15]
if averages.allSatisfy({ $0 != nil }) {
    print("Load average: " + averages.compactMap { $0 }.map { String(format: "%.2f", $0) }.joined(separator: ", "))
} else {
    print("Load average: unavailable")
}

print("")
if case .unavailable(let reason) = profile.sensorsAvailable {
    print("Sensors:      unavailable — \(reason)")
}
if case .unavailable(let reason) = profile.frequencyAvailable {
    print("Frequency:    unavailable — \(reason)")
}

// MARK: - Volumes

print("")
print("=== Volumes ===")
for volume in StorageSampler.volumes() {
    let percent = Int(volume.usedFraction * 100)
    print("\(volume.name): \(formatBytes(volume.usedBytes)) of \(formatBytes(volume.totalBytes)) used (\(percent)%)")
}

// MARK: - Live sampling

print("")
print("=== Live (5 samples at 1 Hz) ===")

let engine = MetricsEngine()
await StandardSamplers.registerAll(on: engine)

let cpuStream = await engine.subscribe(to: .cpu)
let memoryStream = await engine.subscribe(to: .memory)

let memoryTask = Task {
    for await value in memoryStream {
        guard let sample = value.value as? MemorySample else { continue }
        let pressure = sample.pressure.map(String.init(describing:)) ?? "unavailable"
        print("  memory: \(formatBytes(sample.used)) used, \(formatBytes(sample.compressed)) compressed, pressure \(pressure)")
    }
}

var samples = 0
for await value in cpuStream {
    guard let load = value.value as? CPULoadSample else { continue }
    let clusters = load.clusterLoads(for: profile.cpu.clusters)
        .sorted { $0.key < $1.key }
        .map { "\($0.key) \(Int($0.value * 100))%" }
        .joined(separator: ", ")
    print("  cpu: \(Int(load.total * 100))% total  [\(clusters)]")

    samples += 1
    if samples == 5 { break }
}

memoryTask.cancel()

// MARK: - Top processes

print("")
print("=== Top 10 processes by memory ===")

// Unknown footprints sort last; the `?? 0` affects ordering only, never what
// is printed.
let processes = ProcessSampler.snapshot()
    .sorted { ($0.memoryFootprintBytes ?? 0) > ($1.memoryFootprintBytes ?? 0) }
    .prefix(10)

for process in processes {
    let architecture = process.architecture == .translated ? " (Rosetta)" : ""
    let footprint = process.memoryFootprintBytes.map(formatBytes) ?? "unavailable"
    print("  \(process.pid)\t\(footprint)\t\(process.name)\(architecture)")
}
