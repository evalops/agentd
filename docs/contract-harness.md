# Chronicle Contract Harness

`scripts/mock_chronicle.py` is the local strict harness for agentd's Chronicle
and Secret Broker HTTP/JSON contracts.

Run fixture validation:

```sh
python3 scripts/mock_chronicle.py --self-test Tests/Fixtures/chronicle
```

Run a local mock server:

```sh
python3 scripts/mock_chronicle.py --host 127.0.0.1 --port 8787
```

The mock supports the client-facing Chronicle methods agentd needs for local
simulation:

- `RegisterDevice`
- `Heartbeat`
- `GetCapturePolicy`
- `SubmitBatch`
- `PauseSession`
- `ResumeSession`
- `AcknowledgeMemory`

It also supports the Secret Broker `/v1/artifacts:wrap` route used by broker
mode. The harness rejects unknown request fields so generated fixtures act as an
explicit drift gate until agentd can consume generated `chronicle.v1` Swift
types directly.

Golden fixtures live in `Tests/Fixtures/chronicle/` and cover inline
`SubmitBatch`, broker-wrapped submit, heartbeat pause state, policy responses,
server pause windows, malformed policy input, and Secret Broker wrapping.

