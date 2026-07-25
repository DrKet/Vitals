import Foundation

/// Decodes a C-string buffer (`CChar`, i.e. `Int8`) as UTF-8, stopping at the
/// first NUL if one is present.
///
/// Swift 6 deprecates `String(cString:)` for buffers that aren't guaranteed to
/// be a null-terminated `UnsafePointer<CChar>`. Several of the buffers this
/// package reads — fixed-size `sysctl` and kernel-info buffers — are not that:
/// the source string may have been truncated to exactly fill the buffer,
/// leaving no NUL terminator at all. This decodes up to the first NUL when one
/// exists, and falls back to the entire buffer when it doesn't, rather than
/// trapping or reading past the end.
func decodeCString<Buffer: Collection>(_ buffer: Buffer) -> String where Buffer.Element == CChar {
    let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let utf8Buffer = buffer[buffer.startIndex..<nullTerminatorIndex].map { UInt8(bitPattern: $0) }
    return String(decoding: utf8Buffer, as: UTF8.self)
}
