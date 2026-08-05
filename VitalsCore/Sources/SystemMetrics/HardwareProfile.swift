import Foundation

public enum HardwareProfileError: Error, Equatable {
    case installedMemoryUnavailable
    case memoryProfilerFailed(status: Int32)
}

/// Static description of the machine, built once at launch. Consumers use it to
/// decide which pages and fields exist at all, so that inapplicable hardware is
/// absent rather than shown empty.
public struct HardwareProfile: Sendable {
    public let cpu: CPUTopology
    public let memory: MemoryHardware
    public let gpus: [GPUDevice]
    /// Physical block devices from `StorageSampler.devices()`. Empty when
    /// IOKit publishes none with a product name — never a fabricated entry.
    public let storageDevices: [StorageDevice]
    public let sensorsAvailable: MetricAvailability
    public let frequencyAvailable: MetricAvailability
    /// Whether this machine has a battery at all.
    ///
    /// This is the one genuinely static fact about the battery — unlike
    /// maximum capacity or cycle count, which drift over months and so do
    /// not belong on a profile documented as "built once at launch". It
    /// exists here, rather than health itself, because it is what the
    /// sidebar needs to decide whether the Battery page exists; the health
    /// figures live on `MetricsStore`, read lazily by `BatteryHealthReader`.
    public let hasBattery: Bool

    public static func detect(
        sysctl: any SysctlProviding = SystemSysctl(),
        sensors: any SensorProviding = IOHIDSensorProvider()
    ) throws -> HardwareProfile {
        let cpu = CPUTopology.detect(using: sysctl)
        let gpus = GPUSampler.devices()
        let storageDevices = StorageSampler.devices()

        // Installed memory is not optional in the way a sensor reading is —
        // a Mac that cannot report `hw.memsize` is not a machine we can
        // describe, so this throws rather than reporting 0 GB installed.
        guard let memsize = sysctl.integer("hw.memsize"), memsize > 0 else {
            throw HardwareProfileError.installedMemoryUnavailable
        }
        let totalBytes = UInt64(memsize)

        let isUnified = gpus.contains { device in
            if case .unified = device.topology { return true }
            return false
        }

        let memory = try MemoryHardwareParser.parse(
            profilerJSON: try memoryProfilerOutput(),
            totalBytes: totalBytes,
            isUnified: isUnified,
            brand: cpu.brand
        )

        // Whether a battery exists at all is read from the IORegistry, not
        // `system_profiler`: it is the same cheap, fast check `BatterySampler`
        // already does for live readings, so detecting the battery's mere
        // presence does not need the slow profiler subprocess that
        // `BatteryHealthReader` pays for separately, later, and only once.
        let hasBattery = BatterySampler.read() != nil

        return HardwareProfile(
            cpu: cpu,
            memory: memory,
            gpus: gpus,
            storageDevices: storageDevices,
            sensorsAvailable: sensors.availability,
            frequencyAvailable: cpu.frequencyAvailable
                ? .available
                : .unavailable(reason: "CPU frequency requires IOReport, which is not yet implemented"),
            hasBattery: hasBattery
        )
    }

    /// `system_profiler` is the only supported source for memory type and DIMM
    /// layout. It is slow, so it is read once at launch and never polled.
    ///
    /// Throws rather than substituting placeholder JSON: a failure to launch
    /// the tool is a real error, and silently converting it into "memory with
    /// no stated type" would hide a broken installation behind plausible
    /// output.
    private static func memoryProfilerOutput() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPMemoryDataType"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Read before waiting: draining the pipe as the child writes is what
        // keeps a large payload from filling the kernel buffer and deadlocking.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // A non-zero exit can still leave partial output on stdout. Treating
        // that as a successful read would let degraded data through as though
        // it were a clean measurement.
        guard process.terminationStatus == 0 else {
            throw HardwareProfileError.memoryProfilerFailed(status: process.terminationStatus)
        }

        return data
    }
}
