import Foundation

enum LMStudioEvent {
    struct Prediction {
        let modelIdentifier: String
        let endedAt: Date
        let tokensPerSecond: Double
        let predictedTokens: Int
        let generationSeconds: Double
        let timeToFirstToken: Double
    }

    /// A prediction finished; carries LM Studio's own stats.
    case prediction(Prediction)
    /// A model's worker process, from runtime logs (emitted at load and during inference).
    case worker(modelIdentifier: String, pid: pid_t)
    /// One streamed chunk (≈ one token) of an API response.
    case packet(modelIdentifier: String, at: Date)
    /// Prompt prefill progress, 0–100.
    case promptProgress(modelIdentifier: String, percent: Double)
}

/// Tails LM Studio's `lms log stream` sources and turns the lines we care about into events.
final class LMStudioLogs {
    private let onEvents: @MainActor ([LMStudioEvent]) -> Void
    private var streams: [LogStream] = []

    var isRunning: Bool { !streams.isEmpty && streams.allSatisfy(\.isRunning) }

    init(onEvents: @escaping @MainActor ([LMStudioEvent]) -> Void) {
        self.onEvents = onEvents
    }

    func start() {
        guard !isRunning, FileManager.default.isExecutableFile(atPath: ModelSources.lmsPath) else { return }
        stop()
        let onEvents = onEvents
        let deliver: @Sendable ([LMStudioEvent]) -> Void = { events in
            Task { @MainActor in onEvents(events) }
        }
        streams = [
            LogStream(arguments: ["--source", "model", "--filter", "output", "--stats"], parse: Self.parseModel, deliver: deliver),
            LogStream(arguments: ["--source", "runtime"], parse: Self.parseRuntime, deliver: deliver),
            LogStream(arguments: ["--source", "server"], parse: Self.parseServer, deliver: deliver),
        ]
        streams.forEach { $0.start() }
    }

    func stop() {
        streams.forEach { $0.stop() }
        streams = []
    }

    /// Ends `lms log stream --json` children left behind by an instance that crashed or was force-killed;
    /// orphans get reparented to launchd (pid 1).
    static func reapOrphanedStreams() {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
                  String(cString: pathBuffer) == ModelSources.lmsPath
            else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1,
                  let args = RuntimeProcessSampler.arguments(of: pid),
                  args.count > 3, args[1] == "log", args[2] == "stream", args.contains("--json")
            else { continue }
            kill(pid, SIGTERM)
        }
    }

    // MARK: Parsing

    private struct Line<Payload: Decodable>: Decodable {
        let timestamp: Double
        let data: Payload
    }

    private struct ModelPayload: Decodable {
        struct Stats: Decodable {
            let tokensPerSecond: Double?
            let timeToFirstTokenSec: Double?
            let predictedTokensCount: Int?
        }
        let type: String
        let modelIdentifier: String?
        let stats: Stats?
    }

    private struct RuntimePayload: Decodable {
        let modelIdentifier: String?
        let pid: Int32?
    }

    private struct ServerPayload: Decodable {
        let content: String
    }

    private static func parseModel(_ line: Data) -> LMStudioEvent? {
        guard let entry = try? JSONDecoder().decode(Line<ModelPayload>.self, from: line),
              entry.data.type == "llm.prediction.output",
              let model = entry.data.modelIdentifier,
              let stats = entry.data.stats,
              let tokensPerSecond = stats.tokensPerSecond, tokensPerSecond > 0
        else { return nil }

        let tokens = stats.predictedTokensCount ?? 0
        return .prediction(.init(
            modelIdentifier: model,
            endedAt: Date(timeIntervalSince1970: entry.timestamp / 1000),
            tokensPerSecond: tokensPerSecond,
            predictedTokens: tokens,
            generationSeconds: Double(tokens) / tokensPerSecond,
            timeToFirstToken: stats.timeToFirstTokenSec ?? 0
        ))
    }

    private static func parseRuntime(_ line: Data) -> LMStudioEvent? {
        guard let entry = try? JSONDecoder().decode(Line<RuntimePayload>.self, from: line),
              let model = entry.data.modelIdentifier,
              let pid = entry.data.pid
        else { return nil }
        return .worker(modelIdentifier: model, pid: pid)
    }

    private static let packetMarker = Data("Generated packet".utf8)
    private static let progressMarker = Data("Prompt processing progress".utf8)

    /// Server lines look like `[2026-10-06 18:42:32][INFO][model-id] Generated packet: {...}`.
    private static func parseServer(_ line: Data) -> LMStudioEvent? {
        // Most server lines are irrelevant; skip JSON decoding for them.
        let isPacket = line.range(of: packetMarker) != nil
        guard isPacket || line.range(of: progressMarker) != nil,
              let entry = try? JSONDecoder().decode(Line<ServerPayload>.self, from: line)
        else { return nil }

        let parts = entry.data.content.split(separator: "]", maxSplits: 3)
        guard parts.count == 4, parts[2].hasPrefix("[") else { return nil }
        let model = String(parts[2].dropFirst())
        let message = parts[3].trimmingCharacters(in: .whitespaces)

        if isPacket, message.hasPrefix("Generated packet") {
            return .packet(modelIdentifier: model, at: Date(timeIntervalSince1970: entry.timestamp / 1000))
        }
        if message.hasPrefix("Prompt processing progress:"),
           let percent = Double(message.dropFirst("Prompt processing progress:".count)
               .trimmingCharacters(in: .whitespaces)
               .trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
            return .promptProgress(modelIdentifier: model, percent: percent)
        }
        return nil
    }
}

/// One `lms log stream --json` child process, split into lines and parsed off the main thread.
private final class LogStream: @unchecked Sendable {
    private let arguments: [String]
    private let parse: (Data) -> LMStudioEvent?
    private let deliver: @Sendable ([LMStudioEvent]) -> Void
    private var process: Process?
    private var buffer = Data()  // only touched on the pipe's readability queue

    var isRunning: Bool { process?.isRunning == true }

    init(arguments: [String], parse: @escaping (Data) -> LMStudioEvent?, deliver: @escaping @Sendable ([LMStudioEvent]) -> Void) {
        self.arguments = arguments
        self.parse = parse
        self.deliver = deliver
    }

    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ModelSources.lmsPath)
        process.arguments = ["log", "stream", "--json"] + arguments
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
        var events: [LMStudioEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = parse(line) { events.append(event) }
        }
        if !events.isEmpty { deliver(events) }
    }
}
