import Darwin
import Foundation

public enum NetworkSampler {

    /// Walks the `NET_RT_IFLIST2` routing table for per-interface counters.
    public static func counters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return []
        }

        var result: [InterfaceCounters] = []

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0

            while offset < length {
                // Confirm a whole header is present before binding memory to
                // it. `offset < length` only promises one remaining byte, and
                // reading a partially-present struct is undefined behaviour,
                // not merely a wrong value.
                guard length - offset >= MemoryLayout<if_msghdr>.size else { break }

                let header = base.advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr.self).pointee

                // A record claiming to extend past the buffer is malformed;
                // stop rather than trusting its length to advance the cursor.
                let recordLength = Int(header.ifm_msglen)
                guard recordLength > 0, recordLength <= length - offset else { break }
                defer { offset += recordLength }

                guard header.ifm_type == RTM_IFINFO2 else { continue }

                // `if_msghdr2` is the larger struct; a record typed as
                // RTM_IFINFO2 but too short to hold one is skipped.
                guard recordLength >= MemoryLayout<if_msghdr2>.size else { continue }

                let message = base.advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr2.self).pointee

                // Resolve the name from the interface index rather than
                // reaching into the trailing sockaddr_dl. Same result, no
                // pointer arithmetic over a variable-length structure.
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else {
                    continue
                }
                let name = decodeCString(nameBuffer)
                guard !name.isEmpty else { continue }

                let data = message.ifm_data
                result.append(
                    InterfaceCounters(
                        name: name,
                        bytesIn: data.ifi_ibytes,
                        bytesOut: data.ifi_obytes,
                        packetsIn: data.ifi_ipackets,
                        packetsOut: data.ifi_opackets,
                        errorsIn: data.ifi_ierrors,
                        errorsOut: data.ifi_oerrors
                    )
                )
            }
        }

        return result
    }
}
