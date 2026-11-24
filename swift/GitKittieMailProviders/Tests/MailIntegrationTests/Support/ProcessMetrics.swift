import Darwin
import Foundation

/// What the benchmark reads about a process from the kernel: memory, CPU time and disk I/O.
enum ProcessMetrics {
    /// The memory the system charges this process for (what Activity Monitor shows), in bytes.
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Resident set size now, in bytes.
    static func residentSize() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    struct Usage {
        /// User plus system CPU time, in seconds.
        var cpuSeconds: Double
        var diskBytesRead: Int64
        var diskBytesWritten: Int64
        /// Bytes the process wrote, before the file system coalesced them.
        var logicalBytesWritten: Int64

        static func - (lhs: Usage, rhs: Usage) -> Usage {
            Usage(cpuSeconds: lhs.cpuSeconds - rhs.cpuSeconds, diskBytesRead: lhs.diskBytesRead - rhs.diskBytesRead,
                  diskBytesWritten: lhs.diskBytesWritten - rhs.diskBytesWritten,
                  logicalBytesWritten: lhs.logicalBytesWritten - rhs.logicalBytesWritten)
        }
    }

    /// CPU and disk use of a process (this one by default) since it started.
    static func usage(of pid: pid_t = getpid()) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let seconds = ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return Usage(cpuSeconds: seconds, diskBytesRead: Int64(info.ri_diskio_bytesread),
                     diskBytesWritten: Int64(info.ri_diskio_byteswritten), logicalBytesWritten: Int64(info.ri_logical_writes))
    }

    /// Bytes the files under `folder` occupy on disk.
    static func diskUsage(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Bytes one file occupies on disk; 0 when it is missing.
    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    /// Free space on the volume holding `url`, in bytes.
    static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}
