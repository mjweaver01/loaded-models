import Foundation

/// Tails `lms log stream` for model output events, which carry per-prediction stats (tok/s, TTFT, token counts).
/// LM Studio only emits these when a prediction finishes, not while it streams.
final class LMStudioLogStream: @unchecked Sendable {
    struct Prediction {
        let modelIdentifier: String
        let endedAt: Date
        let tokensPerSecond: Double
        let predictedTokens: Int
        let generationSeconds: Double
        let timeToFirstToken: Double
    }

    private let onPrediction: @MainActor (Prediction) -> Void
    private var process: Process?
    private var buffer = Data()  // only touched on the pipe's readability queue

    var isRunning: Bool { process?.isRunning == true }

    init(onPrediction: @escaping @MainActor (Prediction) -> Void) {
        self.onPrediction = onPrediction
    }

    func start() {
        guard !isRunning, FileManager.default.isExecutableFile(atPath: ModelSources.lmsPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ModelSources.lmsPath)
        process.arguments = ["log", "stream", "--source", "model", "--filter", "output", "--stats", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.consume(data)
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let prediction = Self.parse(line) else { continue }
            let onPrediction = onPrediction
            Task { @MainActor in onPrediction(prediction) }
        }
    }

    private struct Line: Decodable {
        struct Payload: Decodable {
            let type: String
            let modelIdentifier: String?
            let stats: Stats?
        }
        struct Stats: Decodable {
            let tokensPerSecond: Double?
            let timeToFirstTokenSec: Double?
            let totalTimeSec: Double?
            let predictedTokensCount: Int?
        }
        let timestamp: Double
        let data: Payload
    }

    private static func parse(_ line: Data) -> Prediction? {
        guard let entry = try? JSONDecoder().decode(Line.self, from: line),
              entry.data.type == "llm.prediction.output",
              let model = entry.data.modelIdentifier,
              let stats = entry.data.stats,
              let tokensPerSecond = stats.tokensPerSecond, tokensPerSecond > 0
        else { return nil }

        let tokens = stats.predictedTokensCount ?? 0
        return Prediction(
            modelIdentifier: model,
            endedAt: Date(timeIntervalSince1970: entry.timestamp / 1000),
            tokensPerSecond: tokensPerSecond,
            predictedTokens: tokens,
            generationSeconds: Double(tokens) / tokensPerSecond,
            timeToFirstToken: stats.timeToFirstTokenSec ?? 0
        )
    }
}
