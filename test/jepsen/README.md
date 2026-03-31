# Jepsen Test Harness (Issue #6)

This directory contains the first-stage Jepsen-style test harness for KubeBrain.

It provides:
- a concurrent workload generator that writes operation history to JSONL;
- a machine-checkable invariant checker;
- a reproducible shell entrypoint with optional fault-command hooks.

## Scope

This harness validates critical invariants from operation history:
- global response revision monotonicity;
- per-key write revision strict increase;
- no phantom resurrection after delete (with overlap-aware checks).

It does **not** implement full formal linearizability checking yet. That is planned as a follow-up.

## Layout

- `harness/main.go`: workload runner.
- `checker/main.go`: invariant checker.
- `history/history.go`: shared record model and JSONL loader.
- `run.sh`: end-to-end runner.
- `artifacts/`: default output directory.

## Quick Start

Run against a reachable KubeBrain endpoint:

```bash
./test/jepsen/run.sh
```

Useful overrides:

```bash
ENDPOINTS=10.0.0.10:2379 \
DURATION=3m \
WORKERS=32 \
KEYS=128 \
./test/jepsen/run.sh
```

Dry run with fixed operation count:

```bash
OPS_PER_WORKER=200 WORKERS=8 ./test/jepsen/run.sh
```

## Fault Injection Hook

You can provide a fault command that runs periodically while workload is running:

```bash
FAULT_CMD='kubectl -n kube-system delete pod -l app=kubebrain --wait=false' \
FAULT_INTERVAL_SEC=60 \
./test/jepsen/run.sh
```

The harness does not hardcode cluster fault logic. It executes `FAULT_CMD` as-is.

## Artifacts

Default outputs:
- `test/jepsen/artifacts/history.jsonl`
- `test/jepsen/artifacts/report.json`

Checker exits non-zero when any invariant fails.

## Manual Commands

Run workload only:

```bash
go run ./test/jepsen/harness -endpoints 127.0.0.1:2379 -duration 2m -out test/jepsen/artifacts/history.jsonl
```

Run checker only:

```bash
go run ./test/jepsen/checker -history test/jepsen/artifacts/history.jsonl -report test/jepsen/artifacts/report.json
```

## Next Steps

- Add richer fault scenario scripts (partition, latency, restart matrix).
- Integrate a full linearizability checker pipeline.
- Add CI gating job for deterministic short Jepsen runs.

