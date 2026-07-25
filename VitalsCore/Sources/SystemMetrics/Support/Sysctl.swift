import Darwin
import Foundation

/// Reads named sysctl values. Abstracted so parsing logic is testable off-device.
public protocol SysctlProviding: Sendable {
    func integer(_ name: String) -> Int64?
    func string(_ name: String) -> String?
}

/// Live sysctl access.
public struct SystemSysctl: SysctlProviding {
    public init() {}

    public func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }

        switch size {
        case MemoryLayout<Int64>.size:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        case MemoryLayout<Int32>.size:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        default:
            return nil
        }
    }

    public func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Truncate at NUL terminator before decoding (CChar is Int8; convert to UInt8 for UTF8 decoding)
        let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
        let utf8Buffer = buffer[0..<nullTerminatorIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: utf8Buffer, as: UTF8.self)
    }
}
