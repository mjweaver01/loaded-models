import Foundation

struct LoadedModel: Identifiable, Equatable {
    enum Source: String {
        case lmStudio = "LM Studio"
        case ollama = "Ollama"
    }

    let id: String
    let identifier: String
    let name: String
    let source: Source
    let path: String?
    let detail: String
    let sizeBytes: UInt64?
    let contextLength: Int?
    let isActive: Bool
    let queued: Int
    let lastUsed: Date?
}

enum ModelSources {
    static let lmsPath = NSHomeDirectory() + "/.lmstudio/bin/lms"
    static let lmStudioREST = URL(string: "http://127.0.0.1:1234/api/v0/models")!
    static let ollamaPS = URL(string: "http://127.0.0.1:11434/api/ps")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        return URLSession(configuration: config)
    }()

    /// Only queries runtimes whose processes are running, so polling never launches LM Studio's daemon.
    static func fetch(lmStudio: Bool, ollama: Bool) async -> [LoadedModel] {
        async let lms = lmStudio ? fetchLMStudio() : []
        async let oll = ollama ? fetchOllama() : []
        return await lms + oll
    }

    // MARK: LM Studio

    private struct RESTList: Decodable {
        struct Entry: Decodable { let state: String? }
        let data: [Entry]
    }

    private struct LMSEntry: Decodable {
        struct Quant: Decodable { let name: String? }
        let identifier: String?
        let modelKey: String
        let displayName: String?
        let path: String?
        let sizeBytes: UInt64?
        let paramsString: String?
        let architecture: String?
        let quantization: Quant?
        let format: String?
        let contextLength: Int?
        let status: String?
        let queued: Int?
        let lastUsedTime: Double?
    }

    private static func fetchLMStudio() async -> [LoadedModel] {
        // The REST endpoint is cheap; skip spawning `lms` when it says nothing is loaded.
        if let (data, _) = try? await session.data(from: lmStudioREST),
           let list = try? JSONDecoder().decode(RESTList.self, from: data),
           !list.data.contains(where: { $0.state == "loaded" }) {
            return []
        }

        guard let data = await runLMS(["ps", "--json"]),
              let entries = try? JSONDecoder().decode([LMSEntry].self, from: data)
        else { return [] }

        return entries.map { entry in
            let detail = [entry.paramsString, entry.quantization?.name, entry.format?.uppercased()]
                .compactMap { $0 }
                .joined(separator: " · ")
            let status = entry.status ?? "idle"
            return LoadedModel(
                id: "lms:" + (entry.identifier ?? entry.modelKey),
                identifier: entry.identifier ?? entry.modelKey,
                name: entry.displayName ?? entry.modelKey,
                source: .lmStudio,
                path: entry.path,
                detail: detail,
                sizeBytes: entry.sizeBytes,
                contextLength: entry.contextLength,
                isActive: status != "idle" || (entry.queued ?? 0) > 0,
                queued: entry.queued ?? 0,
                lastUsed: entry.lastUsedTime.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
    }

    private static func runLMS(_ arguments: [String]) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            guard FileManager.default.isExecutableFile(atPath: lmsPath) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lmsPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }

    // MARK: Ollama

    private struct OllamaResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let parameter_size: String?
                let quantization_level: String?
            }
            let name: String
            let size: UInt64?
            let details: Details?
        }
        let models: [Model]
    }

    private static func fetchOllama() async -> [LoadedModel] {
        guard let (data, _) = try? await session.data(from: ollamaPS),
              let response = try? JSONDecoder().decode(OllamaResponse.self, from: data)
        else { return [] }

        return response.models.map { model in
            LoadedModel(
                id: "ollama:" + model.name,
                identifier: model.name,
                name: model.name,
                source: .ollama,
                path: nil,
                detail: [model.details?.parameter_size, model.details?.quantization_level]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                sizeBytes: model.size,
                contextLength: nil,
                isActive: false,
                queued: 0,
                lastUsed: nil
            )
        }
    }
}
