// `@preconcurrency` is required to read `vm_kernel_page_size` below: Swift 6
// strict concurrency otherwise flags any access to this C mutable global as
// concurrency-unsafe, regardless of how the reading declaration is annotated.
@preconcurrency import Darwin
import Foundation

/// `host_statistics64` reports page counts in kernel page units, which can
/// differ from this process's page size under Rosetta translation. Capturing
/// the kernel global is therefore required for correctness, not a stylistic
/// choice. Immutable after libsystem initialisation.
private let kernelPageSize = vm_kernel_page_size

public enum MemorySampler {
    public static func read() -> MemorySample? {
        guard let counters = readVMCounters() else { return nil }
        let swap = readSwap()
        return MemoryCalculator.sample(
            from: counters,
            swapUsed: swap?.used,
            swapTotal: swap?.total,
            pressure: readPressure()
        )
    }

    static func readVMCounters() -> VMCounters? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return VMCounters(
            free: UInt64(stats.free_count),
            wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count),
            internalPages: UInt64(stats.internal_page_count),
            pageSize: UInt64(kernelPageSize)
        )
    }

    /// `nil` rather than `(0, 0)` on failure: zero swap is a real, meaningful
    /// reading and must not be confused with a failed one.
    static func readSwap() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return (UInt64(usage.xsu_used), UInt64(usage.xsu_total))
    }

    /// `nil` rather than `.normal` on failure or on an unrecognised level:
    /// reporting "normal" for a reading we do not have would be a fabrication.
    static func readPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        // Values from <sys/kern_memorystatus.h>: 1 normal, 2 warning, 4 critical.
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }
}
