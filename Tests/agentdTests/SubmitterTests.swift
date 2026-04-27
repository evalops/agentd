import XCTest
import Foundation
@testable import agentd

final class SubmitterTests: XCTestCase {
    func testSubmitBatchEncodingMatchesChronicleProtoJSONShape() throws {
        let batch = Batch(
            batchId: "batch_fixture",
            deviceId: "device_1",
            organizationId: "org_1",
            workspaceId: "workspace_1",
            userId: "user_1",
            projectId: "project_1",
            repository: "evalops/platform",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            frames: [
                ProcessedFrame(
                    frameHash: String(repeating: "a", count: 64),
                    perceptualHash: 42,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    bundleId: "com.microsoft.VSCode",
                    appName: "Code",
                    windowTitle: "chronicle.proto",
                    documentPath: "/Users/alice/src/platform/proto/chronicle/v1/chronicle.proto",
                    ocrText: "ChronicleService SubmitBatch",
                    ocrConfidence: 0.93,
                    widthPx: 1512,
                    heightPx: 982,
                    bytesPng: 120_000
                )
            ],
            droppedCounts: DropCounts(secret: 0, duplicate: 1, deniedApp: 0, deniedPath: 0)
        )

        let data = try encodeSubmitBatchRequest(batch, localOnly: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["localOnly"] as? Bool, true)
        let encodedBatch = try XCTUnwrap(root["batch"] as? [String: Any])
        XCTAssertEqual(encodedBatch["batchId"] as? String, "batch_fixture")
        XCTAssertEqual(encodedBatch["organizationId"] as? String, "org_1")
        XCTAssertEqual(encodedBatch["projectId"] as? String, "project_1")
        XCTAssertNil(encodedBatch["orgId"])

        let frames = try XCTUnwrap(encodedBatch["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.first?["perceptualHash"] as? String, "42")
        XCTAssertEqual(frames.first?["bytesPng"] as? String, "120000")
        XCTAssertEqual(frames.first?["bundleId"] as? String, "com.microsoft.VSCode")
        XCTAssertEqual(frames.first?["frameHash"] as? String, String(repeating: "a", count: 64))

        let droppedCounts = try XCTUnwrap(encodedBatch["droppedCounts"] as? [String: Any])
        XCTAssertEqual(droppedCounts["duplicate"] as? Int, 1)
    }

    func testAgentConfigDecodesLegacyOrgIdAndEncodesOrganizationId() throws {
        let legacy = """
        {
          "deviceId": "device_1",
          "orgId": "org_legacy",
          "endpoint": "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch",
          "localOnly": true
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AgentConfig.self, from: legacy)
        XCTAssertEqual(cfg.organizationId, "org_legacy")
        XCTAssertEqual(cfg.allowedBundleIds, AgentConfig.defaultAllowedBundleIds)

        let encoded = try JSONEncoder().encode(cfg)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(root["organizationId"] as? String, "org_legacy")
        XCTAssertNil(root["orgId"])
    }
}
