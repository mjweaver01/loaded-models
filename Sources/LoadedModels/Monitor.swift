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
    private(set) var throughput: [String: ModelThroughput] = [:]
    private(set) var lastTokensPerSecond: Double?
    /// Tokens generated per wall-clock second, backfilled when a prediction reports its stats.
    private var tokenBuckets: [Int: Double] = [:]
    let physicalMemory = ProcessInfo.processInfo.physicalMemory

    var latest: Sample? { samples.last }
    var anyActive: Bool { models.contains(where: \.isActive) }
    var modelBytes: UInt64 { models.compactMap(\.sizeBytes).reduce(0, +) }
    var tokensPerSecondSeries: [ChartPoint] {
        samples.map { ChartPoint(id: $0.id, value: tokenBuckets[$0.second] ?? 0) }
    }

    @ObservationIgnored private let sampler = RuntimeProcessSampler()
    @ObservationIgnored private var logStream: LMStudioLogStream?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var fetching = false

    init() {
        logStream = LMStudioLogStream { [weak self] in self?.record($0) }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logStream?.stop() }
        }
    }

    func throughput(for model: LoadedModel) -> ModelThroughput? {
        throughput[model.id]
    }

    private func tick() {
        let gpu = GPUReader.read()
        let runtime = sampler.sample()
        tickCount += 1

        samples.append(Sample(
            id: tickCount,
            second: Int(Date().timeIntervalSince1970),
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

        // Attaching to the log stream would start LM Studio's daemon, so only do it while LM Studio is up.
        if runtime.lmStudioRunning {
            logStream?.start()
        } else if logStream?.isRunning == true {
            logStream?.stop()
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

    private func record(_ prediction: LMStudioLogStream.Prediction) {
        let key = "lms:" + prediction.modelIdentifier
        var stats = throughput[key] ?? ModelThroughput(last: 0, recent: [], lastTokens: 0, lastTimeToFirstToken: 0)
        stats.last = prediction.tokensPerSecond
        stats.lastTokens = prediction.predictedTokens
        stats.lastTimeToFirstToken = prediction.timeToFirstToken
        stats.recent = Array((stats.recent + [prediction.tokensPerSecond]).suffix(Self.recentRuns))
        throughput[key] = stats
        lastTokensPerSecond = prediction.tokensPerSecond

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
        let cutoff = Int(Date().timeIntervalSince1970) - Self.historyLength - 5
        tokenBuckets = tokenBuckets.filter { $0.key >= cutoff }
    }
}
