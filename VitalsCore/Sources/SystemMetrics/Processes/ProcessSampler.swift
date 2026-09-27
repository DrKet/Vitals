import Darwin
import Foundation

public enum ProcessSampler {

    public static func snapshot() -> [ProcessSnapshot] {
        let enumerated = kernelProcesses()
        let read = enumerated.compactMap { process in detail(for: process).map { (process, $0) } }

        // Re-checked AFTER every rusage/taskinfo read, in one sysctl: a process
        // can exit mid-scan, and a zombie's rusage reads back zeroed. Zombie
        // state is one-way, so a process still alive and still the same
        // process now was alive when its counters were read. (One
        // KERN_PROC_ALL instead of a KERN_PROC_PID per process: ~0.1 ms vs
        // ~7 ms per tick.)
        return stillAlive(read, after: kernelProcesses())
    }

    /// Keeps only reads whose process is still present, not a zombie, and
    /// still the same process (raw start-time match) in `after` — see
    /// `snapshot()` for why this runs after every counter read.
    ///
    /// An empty `after` (the re-read itself failed) drops every read — never
    /// falls back to `read` unfiltered, which would reintroduce zeroed
    /// zombies.
    static func stillAlive(
        _ read: [(kinfo_proc, ProcessSnapshot)], after: [kinfo_proc]
    ) -> [ProcessSnapshot] {
        var afterByPID: [pid_t: kinfo_proc] = [:]
        for process in after { afterByPID[process.kp_proc.p_pid] = process }

        return read.compactMap { enumeratedProcess, snapshot in
            guard let current = afterByPID[snapshot.pid],
                  !isZombie(current),
                  current.kp_proc.p_starttime.tv_sec == enumeratedProcess.kp_proc.p_starttime.tv_sec,
                  current.kp_proc.p_starttime.tv_usec == enumeratedProcess.kp_proc.p_starttime.tv_usec
            else { return nil }
            return snapshot
        }
    }

    /// Every process on the system, via `KERN_PROC_ALL`.
    private static func kernelProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }

        let count = length / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &processes, &length, nil, 0) == 0 else {
            return []
        }

        // The table can shrink between the sizing call and the fetch.
        return Array(processes.prefix(length / MemoryLayout<kinfo_proc>.stride))
    }

    private static func detail(for process: kinfo_proc) -> ProcessSnapshot? {
        let pid = process.kp_proc.p_pid
        guard pid > 0 else { return nil }

        // Cheap fast path: already a zombie at enumeration time. `snapshot()`'s
        // single post-read re-check (one KERN_PROC_ALL, after every detail
        // read) is what closes the race for a process that becomes a zombie
        // between enumeration and here.
        guard !isZombie(process) else { return nil }

        errno = 0
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let usageErrno = errno

        errno = 0
        var taskInfo = proc_taskinfo()
        let taskResult = proc_pidinfo(
            pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size)
        )
        let taskErrno = errno

        // Both privileged lookups fail for two distinct reasons: the process
        // exited between enumeration and inspection (ESRCH), or we simply lack
        // the rights to inspect it — e.g. a normal, unprivileged process
        // reading a process owned by another user, most visibly root's
        // daemons. Only the former is skipped as gone. The latter still
        // belongs in the list: `kinfo_proc` already gave us its identity for
        // free, so it is reported with the privileged fields nil rather than
        // dropped entirely.
        let bothFailed = usageResult != 0 && taskResult <= 0
        guard !bothFailed || (usageErrno != ESRCH && taskErrno != ESRCH) else { return nil }

        let name = withUnsafePointer(to: process.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { charPointer in
                let buffer = UnsafeBufferPointer(start: charPointer, count: Int(MAXCOMLEN) + 1)
                return decodeCString(buffer)
            }
        }

        let nanosecondsPerSecond = 1_000_000_000.0
        let cpuTime: Double?
        if usageResult == 0 {
            cpuTime = Double(usage.ri_user_time + usage.ri_system_time) / nanosecondsPerSecond
        } else if taskResult > 0 {
            cpuTime = Double(taskInfo.pti_total_user + taskInfo.pti_total_system) / nanosecondsPerSecond
        } else {
            // Neither privileged call succeeded (permission denied); there is
            // no CPU time to report for this process.
            cpuTime = nil
        }

        return ProcessSnapshot(
            pid: pid,
            parentPID: process.kp_eproc.e_ppid,
            name: name,
            userID: process.kp_eproc.e_ucred.cr_uid,
            memoryFootprintBytes: usageResult == 0 ? usage.ri_phys_footprint : nil,
            cpuTimeSeconds: cpuTime,
            threadCount: taskResult > 0 ? Int(taskInfo.pti_threadnum) : nil,
            diskBytesRead: usageResult == 0 ? usage.ri_diskio_bytesread : nil,
            diskBytesWritten: usageResult == 0 ? usage.ri_diskio_byteswritten : nil,
            architecture: architecture(of: process),
            startTimeSeconds: startTimeSeconds(of: process)
        )
    }

    /// The identity of one process, read afresh from the kernel — `nil` when
    /// no process has that pid.
    ///
    /// This is what `ProcessControl` checks immediately before signalling, so
    /// it must produce exactly what `snapshot()` produced for the same
    /// process. Both go through `startTimeSeconds(of:)`; never convert
    /// `p_starttime` anywhere else. A zombie has exited, so it has no
    /// identity either.
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let process = kernelProcess(pid: pid), !isZombie(process) else { return nil }
        return ProcessIdentity(pid: pid, startTimeSeconds: startTimeSeconds(of: process))
    }

    /// The executable's path (`proc_pidpath`), or `nil` when it cannot be
    /// read — the process exited, or it belongs to another user and the
    /// kernel declines to say.
    public static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` (from `sys/proc_info.h`) is unavailable in
        // this SDK ("structure not supported"), so its own definition —
        // `4 * MAXPATHLEN` — is inlined here instead.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// One process via `KERN_PROC_PID`. For a pid with no process the call
    /// still succeeds but reports a zero length, which is what the length
    /// check catches.
    ///
    /// Internal (not private) so tests can observe a zombie's state.
    static func kernelProcess(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &process, &length, nil, 0) == 0,
              length == MemoryLayout<kinfo_proc>.stride else { return nil }
        return process
    }

    /// A process that has exited but not yet been reaped by its parent.
    /// It still appears in `KERN_PROC_ALL`, and `proc_pid_rusage` on it
    /// succeeds with every counter zeroed — including a 0-byte footprint the
    /// process never had. It has exited: treat it exactly as gone.
    static func isZombie(_ process: kinfo_proc) -> Bool {
        Int32(process.kp_proc.p_stat) == SZOMB
    }

    /// `p_starttime` (a timeval: integer seconds + microseconds) as seconds
    /// since the epoch. The process's identity anchor, not a displayed value.
    ///
    /// The ONE place this conversion is written. `ProcessIdentity` compares
    /// the result exactly, so a second hand-written copy that rounded even
    /// slightly differently could make a live process fail its own identity
    /// check.
    static func startTimeSeconds(of process: kinfo_proc) -> Double {
        Double(process.kp_proc.p_starttime.tv_sec)
            + Double(process.kp_proc.p_starttime.tv_usec) / 1_000_000
    }

    /// `P_TRANSLATED` (from `sys/proc.h`) marks a process running under Rosetta.
    /// This SDK does not expose `PROC_FLAG_TRANSLATED` on `proc_bsdshortinfo`,
    /// so the flag is read directly off the `kinfo_proc` already in hand.
    private static func architecture(of process: kinfo_proc) -> ProcessArchitecture {
        (process.kp_proc.p_flag & P_TRANSLATED) != 0 ? .translated : .native
    }
}
