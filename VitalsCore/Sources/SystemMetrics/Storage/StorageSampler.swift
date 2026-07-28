import Foundation
import IOKit
import IOKit.storage

public enum StorageSampler {

    /// Static description of each physical block storage device, parsed from
    /// `IOBlockStorageDevice` device/protocol characteristics via
    /// `StorageDeviceParser`.
    ///
    /// Virtual / file-backed images (`Physical Interconnect` = "Virtual
    /// Interface") are omitted — they are not hardware. A device whose
    /// characteristics lack a product name is omitted rather than filed under
    /// a placeholder, matching `StorageDeviceParser`'s rejection rule.
    public static func devices() -> [StorageDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDevice"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [StorageDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let deviceCharacteristics = dictionary["Device Characteristics"] as? [String: Any]
            else { continue }

            let protocolCharacteristics =
                dictionary["Protocol Characteristics"] as? [String: Any] ?? [:]

            guard let device = StorageDeviceParser.parse(
                deviceCharacteristics: deviceCharacteristics,
                protocolCharacteristics: protocolCharacteristics
            ) else { continue }

            // Disk images publish as block devices but are not hardware; keep
            // them out of the inventory the UI attributes readings to.
            if device.interconnect == "Virtual Interface" { continue }

            result.append(device)
        }
        return result
    }

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

            // A driver with no discoverable BSD name is skipped rather than
            // filed under a placeholder key. Two nameless drivers would
            // otherwise collide, and — worse — successive samples could key
            // different physical devices identically, feeding DeltaCounter a
            // delta between unrelated disks. An unidentifiable device is
            // omitted, exactly as an unreadable volume is.
            guard let name = (dictionary["BSD Name"] as? String)
                ?? (IORegistryEntrySearchCFProperty(
                        service, kIOServicePlane, "BSD Name" as CFString,
                        kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
                    ) as? String),
                !name.isEmpty
            else { continue }

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
