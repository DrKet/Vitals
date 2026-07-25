import Foundation

public enum HardwareProfileError: Error {
    case installedMemoryUnavailable
}

/// Static description of the machine, built once at launch. Consumers use it to
/// decide which pages and fields exist at all, so that inapplicable hardware is
/// absent rather than shown empty.
public struct HardwareProfile: Sendable {
    public let cpu: CPUTopology
    public let memory: MemoryHardware
    public let gpus: [GPUDevice]
    public let sensorsAvailable: MetricAvailability
    public let frequencyAvailable: MetricAvailability

    public static func detect(
        sysctl: any SysctlProviding = SystemSysctl(),
        sensors: any SensorProviding = UnavailableSensorProvider()
    ) throws -> HardwareProfile {
        let cpu = CPUTopology.detect(using: sysctl)
        let gpus = GPUSampler.devices()

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

        return HardwareProfile(
            cpu: cpu,
            memory: memory,
            gpus: gpus,
            sensorsAvailable: sensors.availability,
            frequencyAvailable: cpu.frequencyAvailable
                ? .available
                : .unavailable(reason: "CPU frequency requires IOReport, which is not yet implemented")
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
