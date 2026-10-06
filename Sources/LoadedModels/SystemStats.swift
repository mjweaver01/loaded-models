import Darwin
import Foundation
import IOKit

struct GPUStats {
    var utilization: Double
    var inUseMemory: UInt64
}

enum GPUReader {
    /// Reads the Apple GPU's PerformanceStatistics from the IORegistry (no root needed).
    static func read() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any]
            else { continue }
            return GPUStats(
                utilization: (perf["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0,
                inUseMemory: (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            )
        }
        return nil
    }
}

struct RuntimeStats {
    var cpuPercent: Double = 0
    var residentBytes: UInt64 = 0
    var lmStudioRunning = false
    var ollamaRunning = false
}

/// Samples CPU and memory of local LLM runtime processes (LM Studio, Ollama, llama.cpp).
final class RuntimeProcessSampler {
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    private enum Runtime { case lmStudio, ollama, other }

    private static func runtime(for path: String) -> Runtime? {
        // The lms CLI (including our own log stream) is a client, not the runtime.
        if path == ModelSources.lmsPath { return nil }
        if path.contains("/LM Studio.app/") || path.contains("/.lmstudio/") { return .lmStudio }
        if path.hasSuffix("/ollama") || path.contains("/Ollama.app/") { return .ollama }
        if path.hasSuffix("/llama-server") || path.hasSuffix("/mlx_lm.server") { return .other }
        return nil
    }

    func sample() -> RuntimeStats {
        let now = mach_absolute_time()
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

        var stats = RuntimeStats()
        var cpu: [pid_t: UInt64] = [:]
        var deltaTicks: UInt64 = 0

        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
                  let runtime = Self.runtime(for: String(cString: pathBuffer))
            else { continue }

            switch runtime {
            case .lmStudio: stats.lmStudioRunning = true
            case .ollama: stats.ollamaRunning = true
            case .other: break
            }

            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }

            // pti_total_* and mach_absolute_time are both in mach ticks, so their ratio needs no conversion.
            let total = info.pti_total_user + info.pti_total_system
            cpu[pid] = total
            stats.residentBytes += info.pti_resident_size
            if let previous = lastCPU[pid], total >= previous {
                deltaTicks += total - previous
            }
        }

        if lastTime != 0, now > lastTime {
            stats.cpuPercent = min(100, Double(deltaTicks) / Double(now - lastTime) / cores * 100)
        }
        lastCPU = cpu
        lastTime = now
        return stats
    }
}

enum SystemMemory {
    /// Matches Activity Monitor's "Memory Used": app + wired + compressed.
    static func used() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }
}
