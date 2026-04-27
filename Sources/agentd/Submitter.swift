import Foundation

/// HTTP/JSON poster against `chronicle.v1.ChronicleService.SubmitBatch`.
/// Local-only mode writes batches to `~/.evalops/agentd/batches/` instead of POSTing.
actor Submitter {
    private let endpoint: URL
    private let localOnly: Bool
    private let session: URLSession

    init(endpoint: URL, localOnly: Bool, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.localOnly = localOnly
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpAdditionalHeaders = [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ]
            cfg.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    @discardableResult
    func submit(_ batch: Batch) async -> SubmitResult {
        let data: Data
        do {
            data = try encodeSubmitBatchRequest(batch, localOnly: localOnly)
        } catch {
            Log.submit.error("batch encode failed id=\(batch.batchId, privacy: .public)")
            return .failed
        }

        if localOnly {
            await persistLocal(batch.batchId, data: data)
            return .persistedLocal
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = data
        do {
            let (body, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Log.submit.warning("submit status=\(http.statusCode, privacy: .public) batch=\(batch.batchId, privacy: .public) — falling back to local")
                await persistLocal(batch.batchId, data: data)
                return .persistedLocal
            } else {
                let response = try? JSONDecoder().decode(SubmitBatchResponse.self, from: body)
                Log.submit.info("submit ok batch=\(batch.batchId, privacy: .public) frames=\(batch.frames.count, privacy: .public)")
                return .submitted(response)
            }
        } catch {
            Log.submit.warning("submit error \(error.localizedDescription, privacy: .public) — falling back to local")
            await persistLocal(batch.batchId, data: data)
            return .persistedLocal
        }
    }

    private func persistLocal(_ id: String, data: Data) async {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".evalops/agentd/batches")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Log.submit.info("local persist \(url.path, privacy: .public)")
    }
}

struct SubmitBatchRequest: Sendable, Codable {
    let batch: Batch
    let localOnly: Bool
}

struct SubmitBatchResponse: Sendable, Codable, Equatable {
    let batchId: String?
    let artifactId: String?
    let acceptedFrameCount: Int?
    let droppedFrameCount: Int?
    let memoryIds: [String]?
}

enum SubmitResult: Sendable, Equatable {
    case submitted(SubmitBatchResponse?)
    case persistedLocal
    case failed
}

func encodeSubmitBatchRequest(_ batch: Batch, localOnly: Bool) throws -> Data {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    return try enc.encode(SubmitBatchRequest(batch: batch, localOnly: localOnly))
}
