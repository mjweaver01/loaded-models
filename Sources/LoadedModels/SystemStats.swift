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

struct ProcessUsage: Equatable {
    var cpuPercent: Double
    var residentBytes: UInt64
}

/// LM Studio runs each loaded model in its own process: MLX models in a node `llmworker`, GGUF models in `llama-server`.
enum ModelProcessKind: Equatable {
    case mlxWorker
    case llamaServer(modelPath: String)
}

struct RuntimeStats {
    var cpuPercent: Double = 0
    var residentBytes: UInt64 = 0
    var lmStudioRunning = false
    var ollamaRunning = false
    var processes: [pid_t: ProcessUsage] = [:]
    var modelProcesses: [pid_t: ModelProcessKind] = [:]
}

/// Samples CPU and memory of local LLM runtime processes (LM Studio, Ollama, llama.cpp).
final class RuntimeProcessSampler {
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private var kindCache: [pid_t: ModelProcessKind?] = [:]
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    private enum Runtime { case lmStudio, ollama, other }

    private static func runtime(for path: String) -> Runtime? {
        // The lms CLI (including our own log streams) is a client, not the runtime.
        if path == ModelSources.lmsPath { return nil }
        if path.contains("/LM Studio.app/") || path.contains("/.lmstudio/") { return .lmStudio }
        if path.hasSuffix("/ollama") || path.contains("/Ollama.app/") { return .ollama }
        if path.hasSuffix("/llama-server") || path.hasSuffix("/mlx_lm.server") { return .other }
        return nil
    }

    func sample() -> RuntimeStats {
        let now = mach_absolute_time()
        let elapsed = lastTime == 0 || now <= lastTime ? 0 : Double(now - lastTime)
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

        var stats = RuntimeStats()
        var cpu: [pid_t: UInt64] = [:]
        var deltaTicks: UInt64 = 0

        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard let runtime = Self.runtime(for: path) else { continue }

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
            var delta: UInt64 = 0
            if let previous = lastCPU[pid], total >= previous {
                delta = total - previous
                deltaTicks += delta
            }
            stats.processes[pid] = ProcessUsage(
                cpuPercent: elapsed > 0 ? min(100, Double(delta) / elapsed / cores * 100) : 0,
                residentBytes: info.pti_resident_size
            )

            if runtime == .lmStudio, let kind = modelProcessKind(pid: pid, path: path) {
                stats.modelProcesses[pid] = kind
            }
        }

        if elapsed > 0 {
            stats.cpuPercent = min(100, Double(deltaTicks) / elapsed / cores * 100)
        }
        lastCPU = cpu
        lastTime = now
        kindCache = kindCache.filter { cpu[$0.key] != nil }
        return stats
    }

    private func modelProcessKind(pid: pid_t, path: String) -> ModelProcessKind? {
        if let cached = kindCache[pid] { return cached }
        var kind: ModelProcessKind?
        if path.hasSuffix("/llama-server") {
            let args = Self.arguments(of: pid) ?? []
            if let index = args.firstIndex(of: "--model"), index + 1 < args.count {
                kind = .llamaServer(modelPath: args[index + 1])
            }
        } else if path.hasSuffix("/node"), Self.arguments(of: pid)?.contains(where: { $0.contains("llmworker.js") }) == true {
            kind = .mlxWorker
        }
        kindCache[pid] = kind
        return kind
    }

    /// Reads a process's argv via sysctl(KERN_PROCARGS2), which works for our own user's processes.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
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
