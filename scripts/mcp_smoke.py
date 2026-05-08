#!/usr/bin/env python3
"""Black-box smoke tests for agentd's local stdio MCP server."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run(binary: Path, args: list[str], *, text: str | None = None, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), *args],
        input=text,
        text=True,
        capture_output=True,
        env=env,
        timeout=20,
        check=False,
    )


def rpc(binary: Path, messages: list[dict[str, Any]], env: dict[str, str]) -> list[dict[str, Any]]:
    payload = "".join(json.dumps(message, separators=(",", ":")) + "\n" for message in messages)
    proc = run(binary, ["mcp"], text=payload, env=env)
    if proc.returncode != 0:
        fail(f"mcp exited {proc.returncode}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def fail(message: str) -> None:
    raise SystemExit(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def response_by_id(responses: list[dict[str, Any]]) -> dict[Any, dict[str, Any]]:
    return {response.get("id"): response for response in responses if "id" in response}


def mcp_text(response: dict[str, Any]) -> dict[str, Any]:
    if "error" in response:
        fail(f"unexpected MCP error: {response}")
    content = response["result"]["content"]
    require(len(content) == 1, f"expected one content item: {response}")
    require(content[0]["type"] == "text", f"expected text content: {response}")
    return json.loads(content[0]["text"])


def write_activity_fixture(directory: Path) -> None:
    now = utc_now()
    frame = {
        "frameHash": "hash-one",
        "perceptualHash": "42",
        "capturedAt": now,
        "bundleId": "com.google.Chrome",
        "appName": "Google Chrome",
        "windowTitle": "Review EvalOps",
        "documentPath": "https://github.com/evalops/platform/pull/123?code=secret&safe=1",
        "tier": "evidence",
        "ocrText": "reviewing agentd mcp smoke",
        "ocrTextTruncated": False,
        "ocrConfidence": 0.93,
        "widthPx": 1440,
        "heightPx": 900,
        "bytesPng": "12",
        "displayId": "1",
        "displayScale": 2,
        "mainDisplay": True,
    }
    batch = {
        "batchId": "batch-one",
        "deviceId": "device-one",
        "organizationId": "org-one",
        "workspaceId": "workspace-one",
        "userId": "user-one",
        "projectId": "project-one",
        "repository": "evalops/agentd",
        "metadata": {
            "activePullRequest": "evalops/agentd#123",
            "activePullRequest.firstSeenAt": now,
            "activePullRequest.foregroundSeconds": "30",
        },
        "startedAt": now,
        "endedAt": now,
        "captureWindow": {"startedAt": now, "endedAt": now},
        "frames": [frame],
        "droppedCounts": {
            "secret": 1,
            "duplicate": 2,
            "deniedApp": 3,
            "deniedPath": 4,
            "droppedBackpressure": 5,
        },
        "droppedReasonCounts": {"window_title_secret": 1},
    }
    (directory / "batch-one.json").write_text(
        json.dumps({"batch": batch, "localOnly": True}, separators=(",", ":")),
        encoding="utf-8",
    )


def smoke(binary: Path, *, packaged: bool = False) -> None:
    require(binary.exists(), f"missing binary: {binary}")
    home = Path(tempfile.mkdtemp(prefix="agentd-mcp-smoke-home."))
    batch_dir = home / ".evalops" / "agentd" / "batches"
    batch_dir.mkdir(parents=True)
    (batch_dir / "plain.json").write_text("{}\n", encoding="utf-8")
    (batch_dir / "encrypted.agentdbatch").write_bytes(b"abcdef")
    fixture_dir = home / "fixture-batches"
    fixture_dir.mkdir()
    write_activity_fixture(fixture_dir)

    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "AGENTD_API_ENDPOINT": "https://user:pass@example.invalid/ingest?token=secret#frag",
        }
    )

    if not packaged:
        help_proc = run(binary, ["--help"], env=env)
        require(help_proc.returncode == 0, f"help failed: {help_proc.stderr}")
        require("mcp config" in help_proc.stdout + help_proc.stderr, "help did not mention mcp config")

        config_proc = run(
            binary,
            ["mcp", "config", "--command", "/tmp/agentd", "--server-name", "evalops-agentd"],
            env=env,
        )
        require(config_proc.returncode == 0, f"mcp config failed: {config_proc.stderr}")
        config = json.loads(config_proc.stdout)
        require(
            config["mcpServers"]["evalops-agentd"] == {"command": "/tmp/agentd", "args": ["mcp"]},
            f"unexpected mcp config: {config}",
        )

    responses = rpc(
        binary,
        [
            {
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "smoke", "version": "1"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            {"jsonrpc": "2.0", "id": "list", "method": "tools/list", "params": {}},
        ],
        env,
    )
    by_id = response_by_id(responses)
    require(set(by_id) == {"init", "list"}, f"unexpected initialize/list responses: {responses}")
    tool_names = [tool["name"] for tool in by_id["list"]["result"]["tools"]]
    for name in [
        "agentd_device_snapshot",
        "agentd_work_context",
        "agentd_activity_recent",
        "agentd_collect_diagnostics",
    ]:
      require(name in tool_names, f"missing tool {name}: {tool_names}")

    if not packaged:
        parse_proc = run(binary, ["mcp"], text="{\n", env=env)
        parse_response = json.loads(parse_proc.stdout)
        require(parse_response["error"]["code"] == -32700, f"bad parse error: {parse_response}")
        error_cases = [
            ("invalid request", {"jsonrpc": "2.0", "id": "missing"}, -32600),
            ("unknown method", {"jsonrpc": "2.0", "id": "unknown", "method": "bogus"}, -32601),
            (
                "unknown tool",
                {
                    "jsonrpc": "2.0",
                    "id": "unknown-tool",
                    "method": "tools/call",
                    "params": {"name": "bogus", "arguments": {}},
                },
                -32602,
            ),
            (
                "invalid args",
                {
                    "jsonrpc": "2.0",
                    "id": "bad-window",
                    "method": "tools/call",
                    "params": {"name": "agentd_activity_recent", "arguments": {"window": "forever"}},
                },
                -32602,
            ),
        ]
        for label, message, code in error_cases:
            response = rpc(binary, [message], env)[0]
            require(response["error"]["code"] == code, f"{label} wrong error: {response}")

    responses = rpc(
        binary,
        [
            {
                "jsonrpc": "2.0",
                "id": "snapshot",
                "method": "tools/call",
                "params": {"name": "agentd_device_snapshot", "arguments": {}},
            },
            {
                "jsonrpc": "2.0",
                "id": "work",
                "method": "tools/call",
                "params": {
                    "name": "agentd_work_context",
                    "arguments": {"window": "24h", "batch_dir": str(fixture_dir)},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "activity",
                "method": "tools/call",
                "params": {
                    "name": "agentd_activity_recent",
                    "arguments": {"window": "24h", "batch_dir": str(fixture_dir)},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "diag",
                "method": "tools/call",
                "params": {
                    "name": "agentd_collect_diagnostics",
                    "arguments": {
                        "includeActivity": True,
                        "batch_dir": str(fixture_dir),
                        "out_dir": str(home / "diagnostics"),
                    },
                },
            },
        ],
        env,
    )
    by_id = response_by_id(responses)
    snapshot = mcp_text(by_id["snapshot"])
    require(snapshot["localBatchStats"] == {"fileCount": 2, "bytes": 9}, f"bad stats: {snapshot}")
    require("?" not in snapshot["endpoint"], f"endpoint query leaked: {snapshot['endpoint']}")

    work = mcp_text(by_id["work"])
    require(work["activity"]["frameCount"] == 1, f"bad work context frame count: {work}")
    require(work["activity"]["activeArtifacts"][0]["label"] == "evalops/agentd#123", f"bad artifacts: {work}")
    require("reviewing agentd mcp smoke" not in json.dumps(work), "work context leaked raw OCR text")
    require(any("No raw frames" in item for item in work["guidance"]), f"missing guidance: {work}")

    activity = mcp_text(by_id["activity"])
    require(activity["batchCount"] == 1 and activity["frameCount"] == 1, f"bad activity: {activity}")
    require(
        activity["windows"][0]["documentPath"]
        == "https://github.com/evalops/platform/pull/123?code=REDACTED&safe=1",
        f"document path not redacted: {activity['windows'][0]}",
    )

    diagnostics = mcp_text(by_id["diag"])
    for path in [diagnostics["instructionsPath"], *diagnostics["resourcePaths"]]:
        require(Path(path).exists(), f"diagnostic artifact missing: {path}")

    label = "packaged" if packaged else "debug"
    print(f"{label} MCP smoke: ok ({binary})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/agentd", type=Path)
    parser.add_argument("--packaged-binary", type=Path)
    args = parser.parse_args()

    smoke(args.binary)
    if args.packaged_binary is not None:
        smoke(args.packaged_binary, packaged=True)


if __name__ == "__main__":
    main()
