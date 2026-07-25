import Foundation
import IOKit
import Metal

public enum GPUSampler {

    /// One sample per accelerator currently published by IOKit.
    public static func read() -> [GPUSample] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var samples: [GPUSample] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any],
                  let sample = GPUStatisticsParser.parse(statistics)
            else { continue }

            samples.append(sample)
        }
        return samples
    }

    /// Static description of each Metal device.
    public static func devices() -> [GPUDevice] {
        MTLCopyAllDevices().map { device in
            let topology: GPUMemoryTopology = device.hasUnifiedMemory
                ? .unified(systemBytes: device.recommendedMaxWorkingSetSize)
                : .dedicated(vramBytes: device.recommendedMaxWorkingSetSize)

            return GPUDevice(
                name: device.name,
                topology: topology,
                coreCount: nil
            )
        }
    }
}
