import Darwin
import Foundation

public enum ProcessSampler {

    public static func snapshot() -> [ProcessSnapshot] {
        kernelProcesses().compactMap(detail(for:))
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
                let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
                let utf8Buffer = buffer[0..<nullTerminatorIndex].map { UInt8(bitPattern: $0) }
                return String(decoding: utf8Buffer, as: UTF8.self)
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
            architecture: architecture(of: process)
        )
    }

    /// `P_TRANSLATED` (from `sys/proc.h`) marks a process running under Rosetta.
    /// This SDK does not expose `PROC_FLAG_TRANSLATED` on `proc_bsdshortinfo`,
    /// so the flag is read directly off the `kinfo_proc` already in hand.
    private static func architecture(of process: kinfo_proc) -> ProcessArchitecture {
        (process.kp_proc.p_flag & P_TRANSLATED) != 0 ? .translated : .native
    }
}
