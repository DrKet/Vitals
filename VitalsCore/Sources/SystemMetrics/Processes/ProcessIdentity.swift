import Darwin

/// A process's identity across sampling ticks: its pid plus when it started.
///
/// `pid` alone is not an identity — the kernel recycles pids, so anything held
/// by pid would silently transfer to whatever new process inherits it. With a
/// Quit or Force Quit on top, that is an action aimed at the wrong process.
/// `startTimeSeconds` (from `p_starttime`) distinguishes them.
///
/// Lives in `SystemMetrics` so both the UI's selection and `ProcessControl`'s
/// pre-signal re-check can use it; every identity the app *compares* is
/// produced by `ProcessSampler.startTimeSeconds(of:)`, so the two sides
/// always agree. (Tests construct arbitrary ones deliberately, since the
/// public initializer allows any value.)
///
/// `Hashable` is synthesized. Its equality compares `startTimeSeconds`
/// exactly, which is correct and deliberate: the value is a kernel constant
/// converted by one shared function, so the same process reports a
/// bit-identical value every read and a recycled pid reports a genuinely
/// different one. This is identity comparison, not the computed-float
/// comparison the project's float-equality rule warns against.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSeconds: Double

    public init(pid: pid_t, startTimeSeconds: Double) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
    }
}
