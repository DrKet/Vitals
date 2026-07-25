import Foundation
import IOKit
import IOKit.storage

public enum StorageSampler {

    /// Mounted volumes with capacity. Uses
    /// `volumeAvailableCapacityForImportantUsageKey`, which accounts for
    /// APFS purgeable space and therefore matches what Finder reports.
    public static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url in
            // A volume whose capacity or free space we cannot read is omitted
            // rather than reported with zeroes — zero available space would
            // read as a full disk, which is a lie, not a missing value.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacityForImportantUsage,
                  available >= 0
            else { return nil }

            return Volume(
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: UInt64(total),
                availableBytes: UInt64(available),
                isInternal: values.volumeIsInternal ?? false
            )
        }
    }

    /// Cumulative byte counters per block storage driver, keyed by BSD name.
    /// Convert to throughput with `DeltaCounter`.
    public static func ioCounters() -> [String: StorageIOCounters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [String: StorageIOCounters] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["Statistics"] as? [String: Any]
            else { continue }

            let name = (dictionary["BSD Name"] as? String)
                ?? (IORegistryEntrySearchCFProperty(
                        service, kIOServicePlane, "BSD Name" as CFString,
                        kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
                    ) as? String)
                ?? "unknown"

            // A driver that does not publish both counters is skipped. Zero
            // would be indistinguishable from a genuinely idle disk and would
            // then feed a fabricated throughput of 0 B/s into DeltaCounter.
            guard let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
                  let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value
            else { continue }

            result[name] = StorageIOCounters(bytesRead: read, bytesWritten: written)
        }
        return result
    }
}
