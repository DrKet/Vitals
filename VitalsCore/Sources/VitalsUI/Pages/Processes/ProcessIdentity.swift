import Darwin

/// A process's identity across sampling ticks: its pid plus when it started.
///
/// `pid` alone is not an identity — the kernel recycles pids, so a selection
/// held by pid would silently transfer to whatever new process inherits it,
/// and with a context menu on top that is an action aimed at the wrong
/// process. `startTimeSeconds` (from `p_starttime`) distinguishes them.
///
/// `Hashable` is synthesized. Its equality compares `startTimeSeconds`
/// exactly, which is correct and deliberate: the value is a kernel constant
/// stored without any arithmetic, so the same process reports a bit-identical
/// value every tick and a recycled pid reports a genuinely different one.
/// This is identity comparison, not the computed-float comparison the
/// project's float-equality rule warns against.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSeconds: Double

    public init(pid: pid_t, startTimeSeconds: Double) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
    }
}
