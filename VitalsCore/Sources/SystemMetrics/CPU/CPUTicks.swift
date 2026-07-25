import Darwin
import Foundation

/// Raw cumulative scheduler ticks for one logical core.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var total: UInt64 { user &+ system &+ idle &+ nice }
}

/// Reads cumulative per-core ticks from the Mach host.
public enum CPUTickReader {
    public static func read() -> [CPUTicks]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        // `integer_t` is signed but carries an unsigned tick count; reinterpret
        // the bit pattern so large values do not appear negative.
        func tick(_ raw: integer_t) -> UInt64 {
            UInt64(UInt32(bitPattern: raw))
        }

        return (0..<Int(coreCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: tick(info[base + Int(CPU_STATE_USER)]),
                system: tick(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: tick(info[base + Int(CPU_STATE_IDLE)]),
                nice: tick(info[base + Int(CPU_STATE_NICE)])
            )
        }
    }
}
