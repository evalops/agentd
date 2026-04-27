import Foundation

/// HTTP/JSON poster against `chronicle.v1.ChronicleService.SubmitBatch`.
/// Local-only mode writes batches to `~/.evalops/agentd/batches/` instead of POSTing.
actor Submitter {
    private let endpoint: URL
    private let localOnly: Bool
    private let session: URLSession

    init(endpoint: URL, localOnly: Bool) {
        self.endpoint = endpoint
        self.localOnly = localOnly
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Content-Type": "application/json"]
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    func submit(_ batch: Batch) async {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(batch) else {
            Log.submit.error("batch encode failed id=\(batch.id, privacy: .public)")
            return
        }

        if localOnly {
            await persistLocal(batch.id, data: data)
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = data
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Log.submit.warning("submit status=\(http.statusCode, privacy: .public) batch=\(batch.id, privacy: .public) — falling back to local")
                await persistLocal(batch.id, data: data)
            } else {
                Log.submit.info("submit ok batch=\(batch.id, privacy: .public) frames=\(batch.frames.count, privacy: .public)")
            }
        } catch {
            Log.submit.warning("submit error \(error.localizedDescription, privacy: .public) — falling back to local")
            await persistLocal(batch.id, data: data)
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
