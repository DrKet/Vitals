import Foundation

/// Which column the table is sorted by.
public enum ProcessSortField: String, Sendable, CaseIterable {
    case name, cpu, memory, pid, user, threads, cpuTime, diskRead, diskWrite, architecture
}

/// Orders process rows, keeping unreadable values in a group of their own at
/// the end.
///
/// `KeyPathComparator` cannot express this: it would need a value to compare,
/// and the only candidate — zero — is a claim the machine never made. A process
/// whose CPU time could not be read is not idle; it is unknown, and ascending
/// order must not promote it above a process measured at 0.1%.
///
/// The unknown group therefore sits last in BOTH directions. `order` applies to
/// readable values only.
public struct ProcessComparator: SortComparator, Sendable {

    public var order: SortOrder
    public let field: ProcessSortField

    public init(field: ProcessSortField, order: SortOrder) {
        self.field = field
        self.order = order
    }

    public func compare(_ lhs: ProcessRow, _ rhs: ProcessRow) -> ComparisonResult {
        switch field {
        case .name:
            return applying(compareStrings(lhs.name, rhs.name))
        case .user:
            return applying(compareStrings(lhs.userName, rhs.userName))
        case .architecture:
            return applying(compareStrings(
                ProcessRow.formatArchitecture(lhs.architecture),
                ProcessRow.formatArchitecture(rhs.architecture)
            ))
        case .pid:
            return applying(compareValues(Double(lhs.pid), Double(rhs.pid)))
        case .cpu:
            return compareOptional(lhs.cpuFraction, rhs.cpuFraction)
        case .memory:
            return compareOptional(lhs.memoryBytes.map(Double.init), rhs.memoryBytes.map(Double.init))
        case .threads:
            return compareOptional(lhs.threadCount.map(Double.init), rhs.threadCount.map(Double.init))
        case .cpuTime:
            return compareOptional(lhs.cpuTimeSeconds, rhs.cpuTimeSeconds)
        case .diskRead:
            return compareOptional(lhs.diskReadBytes.map(Double.init), rhs.diskReadBytes.map(Double.init))
        case .diskWrite:
            return compareOptional(lhs.diskWrittenBytes.map(Double.init), rhs.diskWrittenBytes.map(Double.init))
        }
    }

    /// Presence is decided before value, and is NOT flipped by `order` — that
    /// is the whole point. Two absences tie, so their existing relative order
    /// survives a stable sort.
    private func compareOptional(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (left?, right?): return applying(compareValues(left, right))
        }
    }

    private func compareValues(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// Case-insensitive so "Xcode" files beside "finder" rather than ahead of
    /// every lowercase name.
    private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedCaseInsensitiveCompare(rhs)
    }

    private func applying(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
