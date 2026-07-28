import Foundation
import MetricsEngine

/// Pure maths behind the process table. Every decision the design makes about
/// absence, ordering and shading lives here rather than in the view, so each
/// one has a direct test.
public enum ProcessTable {

    /// Builds rows from one sample. A process absent from `cpuUsage` keeps a
    /// `nil` fraction — the sampler omits a process whose CPU time it could not
    /// read, and defaulting to zero here would undo that.
    @MainActor
    public static func rows(from sample: ProcessSeriesSample, resolver: UserNameResolver) -> [ProcessRow] {
        sample.processes.map { snapshot in
            ProcessRow(
                snapshot: snapshot,
                cpuFraction: sample.cpuUsage[snapshot.pid],
                userName: resolver.name(for: snapshot.userID)
            )
        }
    }

    /// Case-insensitive substring match on the name, plus an exact pid match
    /// when the query is a number. A blank query filters nothing.
    public static func filtered(_ rows: [ProcessRow], query: String) -> [ProcessRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }

        let pid = pid_t(trimmed)
        return rows.filter { row in
            if let pid, row.pid == pid { return true }
            return row.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Reorders `rows` to follow an established display order.
    ///
    /// This is what "values update, order holds" means: rows keep their slots
    /// while their numbers change, so a row can be read without it moving.
    /// Processes that exited drop out; processes that started are appended
    /// rather than inserted, since inserting is the same jump re-sorting would
    /// have caused.
    public static func ordered(_ rows: [ProcessRow], keeping order: [pid_t]) -> [ProcessRow] {
        guard !order.isEmpty else { return rows }

        var byPID = [pid_t: ProcessRow](minimumCapacity: rows.count)
        for row in rows { byPID[row.pid] = row }

        var result: [ProcessRow] = []
        result.reserveCapacity(rows.count)
        var placed = Set<pid_t>(minimumCapacity: rows.count)

        for pid in order {
            guard let row = byPID[pid] else { continue }   // exited since the last sort
            result.append(row)
            placed.insert(pid)
        }
        for row in rows where !placed.contains(row.pid) {  // started since the last sort
            result.append(row)
        }
        return result
    }

    /// The largest readable value in a column, or `nil` when nothing in it is
    /// readable. Computed once per sample — doing it per cell would be one
    /// pass over every row for every row.
    public static func maximum(of value: (ProcessRow) -> Double?, in rows: [ProcessRow]) -> Double? {
        rows.compactMap(value).max()
    }

    /// How saturated a heat-map cell should be, `0...1`.
    ///
    /// `nil` for an unreadable value — absence is not a low value and must not
    /// be shaded as one — and `nil` when the column has no positive maximum,
    /// which also avoids dividing by zero on an idle column.
    public static func heatFraction(_ value: Double?, maximum: Double?) -> Double? {
        guard let value, let maximum, maximum > 0 else { return nil }
        return min(max(value / maximum, 0), 1)
    }
}
