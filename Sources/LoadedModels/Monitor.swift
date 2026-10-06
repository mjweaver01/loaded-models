import AppKit
import Foundation
import Observation

struct ChartPoint: Identifiable {
    let id: Int
    let value: Double
}

struct ModelThroughput: Equatable {
    var last: Double
    var recent: [Double]
    var lastTokens: Int
    var lastTimeToFirstToken: Double

    var average: Double { recent.reduce(0, +) / Double(max(recent.count, 1)) }
}

/// Everything the UI shows for one loaded model.
struct ModelStats {
    var throughput: ModelThroughput?
    var liveTokensPerSecond: Double?
    var promptProgress: Double?
    var usage: ProcessUsage?
}

@MainActor
@Observable
final class Monitor {
    struct Sample: Identifiable {
        let id: Int
        let second: Int
        let gpu: Double
        let cpu: Double
        let gpuMemoryGB: Double
    }

    static let historyLength = 120
    static let recentRuns = 20

    private(set) var samples: [Sample] = []
    private(set) var models: [LoadedModel] = []
    private(set) var runtimeRunning = false
    private(set) var lmStudioRunning = false
    private(set) var systemMemoryUsed: UInt64 = 0
    private(set) var runtimeResident: UInt64 = 0
    private(set) var lastTokensPerSecond: Double?
    private var throughput: [String: ModelThroughput] = [:]
    private var liveRates: [String: Double] = [:]
    private var promptProgress: [String: Double] = [:]
    private var modelUsage: [String: ProcessUsage] = [:]
    /// Tokens per wall-clock second from finished predictions, backfilled across each generation's window.
    private var tokenBuckets: [Int: Double] = [:]
    /// Streamed packets per second for predictions still running, keyed by model. Replaced by stats on finish.
    private var liveBuckets: [String: [Int: Int]] = [:]
    let physicalMemory = ProcessInfo.processInfo.physicalMemory

    var latest: Sample? { samples.last }
    var anyActive: Bool { models.contains(where: \.isActive) }
    /// Real memory of each model's process where known, otherwise its size on disk.
    var modelBytes: UInt64 {
        models.compactMap { modelUsage[$0.id]?.residentBytes ?? $0.sizeBytes }.reduce(0, +)
    }
    var tokensPerSecondSeries: [ChartPoint] {
        samples.map { sample in
            let live = liveBuckets.values.reduce(0) { $0 + ($1[sample.second] ?? 0) }
            return ChartPoint(id: sample.id, value: (tokenBuckets[sample.second] ?? 0) + Double(live))
        }
    }

    @ObservationIgnored private let sampler = RuntimeProcessSampler()
    @ObservationIgnored private var logs: LMStudioLogs?
    @ObservationIgnored private var workerPIDs: [String: pid_t] = [:]
    @ObservationIgnored private var lastPacketAt: [String: Date] = [:]
    @ObservationIgnored private var finishedAt: [String: Date] = [:]
    @ObservationIgnored private var progressUpdatedAt: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var fetching = false

    init() {
        LMStudioLogs.reapOrphanedStreams()
        logs = LMStudioLogs { [weak self] events in self?.handle(events) }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logs?.stop() }
        }
        // `kill`/`pkill` skip willTerminate; stop the lms children ourselves so they don't outlive us.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.logs?.stop() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func stats(for model: LoadedModel) -> ModelStats {
        ModelStats(
            throughput: throughput[model.id],
            liveTokensPerSecond: liveRates[model.id],
            promptProgress: promptProgress[model.id],
            usage: modelUsage[model.id]
        )
    }

    private func tick() {
        let gpu = GPUReader.read()
        let runtime = sampler.sample()
        let now = Date()
        tickCount += 1

        samples.append(Sample(
            id: tickCount,
            second: Int(now.timeIntervalSince1970),
            gpu: gpu?.utilization ?? 0,
            cpu: runtime.cpuPercent,
            gpuMemoryGB: Double(gpu?.inUseMemory ?? 0) / 1_073_741_824
        ))
        if samples.count > Self.historyLength {
            samples.removeFirst(samples.count - Self.historyLength)
        }

        systemMemoryUsed = SystemMemory.used()
        runtimeResident = runtime.residentBytes
        lmStudioRunning = runtime.lmStudioRunning
        runtimeRunning = runtime.lmStudioRunning || runtime.ollamaRunning
        resolveModelUsage(runtime)
        updateLiveRates(now: now)
        if Self.debug { printDebugLine() }

        // Attaching to the log streams would start LM Studio's daemon, so only do it while LM Studio is up.
        if runtime.lmStudioRunning {
            logs?.start()
        } else if logs?.isRunning == true {
            logs?.stop()
        }

        // Model lists change rarely; poll every 2s and never overlap requests.
        guard tickCount % 2 == 1, !fetching else { return }
        fetching = true
        Task {
            let fetched = await ModelSources.fetch(lmStudio: runtime.lmStudioRunning, ollama: runtime.ollamaRunning)
            if fetched != models { models = fetched }
            fetching = false
        }
    }

    /// Run the binary with LOADED_MODELS_DEBUG=1 to print per-model stats each second.
    private static let debug = ProcessInfo.processInfo.environment["LOADED_MODELS_DEBUG"] != nil

    private func printDebugLine() {
        let rows = models.map { model in
            let stats = stats(for: model)
            let memory = stats.usage.map { String(format: "%.2fGB %.1f%%cpu", Double($0.residentBytes) / 1_073_741_824, $0.cpuPercent) } ?? "no-proc"
            let live = stats.liveTokensPerSecond.map { String(format: " live=%.0f", $0) } ?? ""
            let last = stats.throughput.map { String(format: " last=%.1f", $0.last) } ?? ""
            let progress = stats.promptProgress.map { String(format: " prompt=%.0f%%", $0) } ?? ""
            return "\(model.identifier)[\(memory)\(live)\(last)\(progress)\(model.isActive ? " active" : "")]"
        }
        print("gpu=\(Int(latest?.gpu ?? 0))% tok/s=\(Int(tokensPerSecondSeries.last?.value ?? 0)) chartTotal=\(Int(tokensPerSecondSeries.map(\.value).reduce(0, +))) \(rows.joined(separator: " "))")
        fflush(stdout)
    }

    // MARK: Per-model processes

    private func resolveModelUsage(_ runtime: RuntimeStats) {
        workerPIDs = workerPIDs.filter { runtime.processes[$0.value] != nil }

        var usage: [String: ProcessUsage] = [:]
        var claimed = Set<pid_t>()
        var unresolved: [LoadedModel] = []

        for model in models where model.source == .lmStudio {
            // Runtime logs name the pid directly; llama-server's --model argument is the fallback.
            let pid = workerPIDs[model.identifier] ?? model.path.flatMap { path in
                runtime.modelProcesses.first { entry in
                    if case .llamaServer(let modelPath) = entry.value { return modelPath.contains(path) }
                    return false
                }?.key
            }
            if let pid, !claimed.contains(pid), let processUsage = runtime.processes[pid] {
                usage[model.id] = processUsage
                claimed.insert(pid)
            } else {
                unresolved.append(model)
            }
        }

        // Models loaded before we started listening, with no activity since: one leftover worker must be the one leftover model.
        let unclaimed = runtime.modelProcesses.keys.filter { !claimed.contains($0) }
        if unresolved.count == 1, unclaimed.count == 1, let processUsage = runtime.processes[unclaimed[0]] {
            usage[unresolved[0].id] = processUsage
        }

        if usage != modelUsage { modelUsage = usage }
    }

    // MARK: Log events

    private func handle(_ events: [LMStudioEvent]) {
        for event in events {
            switch event {
            case .prediction(let prediction):
                record(prediction)
            case .worker(let model, let pid):
                workerPIDs[model] = pid
            case .packet(let model, let date):
                let key = "lms:" + model
                // The server and model logs are separate streams; drop packets of a prediction already reported.
                if let finished = finishedAt[key], date <= finished { continue }
                liveBuckets[key, default: [:]][Int(date.timeIntervalSince1970), default: 0] += 1
                lastPacketAt[key] = date
                promptProgress[key] = nil
            case .promptProgress(let model, let percent):
                let key = "lms:" + model
                promptProgress[key] = percent
                progressUpdatedAt[key] = Date()
            }
        }
    }

    /// Streamed packets are roughly one token each; average the last two full seconds.
    private func updateLiveRates(now: Date) {
        let second = Int(now.timeIntervalSince1970)
        var rates: [String: Double] = [:]
        for (key, counts) in liveBuckets {
            guard let last = lastPacketAt[key], now.timeIntervalSince(last) < 3 else { continue }
            let rate = Double((counts[second - 1] ?? 0) + (counts[second - 2] ?? 0)) / 2
            if rate > 0 { rates[key] = rate }
        }
        if rates != liveRates { liveRates = rates }

        let cutoff = second - Self.historyLength - 5
        if tokenBuckets.keys.contains(where: { $0 < cutoff }) {
            tokenBuckets = tokenBuckets.filter { $0.key >= cutoff }
        }
        if liveBuckets.values.contains(where: { $0.keys.contains { $0 < cutoff } }) {
            liveBuckets = liveBuckets.compactMapValues { counts in
                let recent = counts.filter { $0.key >= cutoff }
                return recent.isEmpty ? nil : recent
            }
        }

        // Progress lines stop once generation starts; drop any that went stale (e.g. a cancelled request).
        for (key, updated) in progressUpdatedAt where now.timeIntervalSince(updated) > 30 {
            promptProgress[key] = nil
            progressUpdatedAt[key] = nil
        }
    }

    private func record(_ prediction: LMStudioEvent.Prediction) {
        let key = "lms:" + prediction.modelIdentifier
        var stats = throughput[key] ?? ModelThroughput(last: 0, recent: [], lastTokens: 0, lastTimeToFirstToken: 0)
        stats.last = prediction.tokensPerSecond
        stats.lastTokens = prediction.predictedTokens
        stats.lastTimeToFirstToken = prediction.timeToFirstToken
        stats.recent = Array((stats.recent + [prediction.tokensPerSecond]).suffix(Self.recentRuns))
        throughput[key] = stats
        lastTokensPerSecond = prediction.tokensPerSecond
        promptProgress[key] = nil
        liveRates[key] = nil
        liveBuckets[key] = nil
        finishedAt[key] = prediction.endedAt

        // Spread the generated tokens across the seconds the generation actually ran.
        let end = prediction.endedAt.timeIntervalSince1970
        var cursor = end - prediction.generationSeconds
        let rate = prediction.tokensPerSecond
        while cursor < end {
            let second = cursor.rounded(.down)
            let next = min(second + 1, end)
            tokenBuckets[Int(second), default: 0] += rate * (next - cursor)
            cursor = next
        }
    }
}
