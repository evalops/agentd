#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1

"""Strict local mock for the agentd Chronicle and Secret Broker contracts."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


CHRONICLE_METHODS = {
    "RegisterDevice": {"deviceId", "organizationId", "workspaceId", "userId", "hostname", "appVersion", "metadata"},
    "Heartbeat": {"deviceId", "organizationId", "pendingFrameCount", "pendingBytes", "paused", "pauseReason"},
    "GetCapturePolicy": {"deviceId", "organizationId"},
    "SubmitBatch": {"batch", "localOnly", "secretBrokerSessionToken", "secretBrokerArtifactId", "secretBrokerGrantId"},
    "PauseSession": {"deviceId", "organizationId", "reason"},
    "ResumeSession": {"deviceId", "organizationId", "reason"},
    "AcknowledgeMemory": {"deviceId", "organizationId", "memoryIds"},
}

FRAME_KEYS = {
    "frameHash",
    "perceptualHash",
    "capturedAt",
    "bundleId",
    "appName",
    "windowTitle",
    "documentPath",
    "ocrText",
    "ocrTextTruncated",
    "ocrConfidence",
    "widthPx",
    "heightPx",
    "bytesPng",
    "displayId",
    "displayScale",
    "mainDisplay",
}

BATCH_KEYS = {
    "batchId",
    "deviceId",
    "organizationId",
    "workspaceId",
    "userId",
    "projectId",
    "repository",
    "startedAt",
    "endedAt",
    "captureWindow",
    "frames",
    "droppedCounts",
}

WRAP_KEYS = {
    "session_token",
    "tool",
    "capability",
    "resource_ref",
    "ttl_seconds",
    "reason",
    "secret_data",
    "metadata",
}


def assert_known(name: str, value: dict[str, Any], allowed: set[str]) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ValueError(f"{name} has unknown fields: {', '.join(unknown)}")


def validate_chronicle(method: str, body: dict[str, Any]) -> None:
    if method not in CHRONICLE_METHODS:
        raise ValueError(f"unsupported Chronicle method {method}")
    assert_known(method, body, CHRONICLE_METHODS[method])
    if method == "SubmitBatch" and isinstance(body.get("batch"), dict):
        batch = body["batch"]
        assert_known("SubmitBatch.batch", batch, BATCH_KEYS)
        if "captureWindow" not in batch:
            raise ValueError("SubmitBatch.batch missing captureWindow")
        for frame in batch.get("frames", []):
            if not isinstance(frame, dict):
                raise ValueError("SubmitBatch.batch.frames must contain objects")
            assert_known("SubmitBatch.batch.frames[]", frame, FRAME_KEYS)


def validate_secret_broker(body: dict[str, Any]) -> None:
    assert_known("SecretBroker.wrap", body, WRAP_KEYS)
    secret_data = body.get("secret_data", {})
    if "chronicle_frame_batch_json" not in secret_data:
        raise ValueError("SecretBroker.wrap missing chronicle_frame_batch_json")
    json.loads(secret_data["chronicle_frame_batch_json"])


def load_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def self_test(fixtures: Path) -> None:
    cases = {
        "inline_submit_batch.json": lambda data: validate_chronicle("SubmitBatch", data),
        "broker_submit_batch.json": lambda data: validate_chronicle("SubmitBatch", data),
        "heartbeat_request.json": lambda data: validate_chronicle("Heartbeat", data),
        "policy_response.json": lambda data: None,
        "server_pause_policy.json": lambda data: None,
        "malformed_policy.json": lambda data: None,
        "secret_broker_wrap.json": validate_secret_broker,
    }
    for name, validator in cases.items():
        validator(load_json(fixtures / name))
    print(f"validated {len(cases)} contract fixtures in {fixtures}")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        try:
            if self.path == "/v1/artifacts:wrap":
                validate_secret_broker(body)
                response = {"grant_id": "grant_local", "artifact_id": "artifact_local"}
            else:
                method = self.path.rstrip("/").split("/")[-1]
                validate_chronicle(method, body)
                response = self.response_for(method)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        except Exception as exc:  # pragma: no cover - exercised through manual server use
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}).encode())

    @staticmethod
    def response_for(method: str) -> dict[str, Any]:
        if method == "RegisterDevice":
            return {"device": {"deviceId": "local", "organizationId": "local", "paused": False}}
        if method == "Heartbeat":
            return {"policy": {"policyVersion": "mock", "captureMode": "CAPTURE_MODE_HYBRID"}}
        if method == "SubmitBatch":
            return {"batchId": "mock_batch", "acceptedFrameCount": 1, "droppedFrameCount": 0}
        return {}


def serve(host: str, port: int) -> None:
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"mock Chronicle listening on http://{host}:{port}")
    server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    if args.self_test:
        self_test(args.self_test)
    else:
        serve(args.host, args.port)


if __name__ == "__main__":
    main()
