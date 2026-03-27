# KWOK Benchmark Comparison

This benchmark compares control-plane performance between:

- `etcd` (baseline): standard kwok cluster
- `kubebrain` (modified): kube-apiserver redirected to KubeBrain etcd-compatible endpoint

The benchmark target is:

- `100` fake nodes
- `10000` pods (Deployment replicas)

## Prerequisites

- `kwokctl`
- `kind`
- `kubectl`
- `docker`
- `make`

## Run

```bash
make bench-kwok-compare
```

Result file:

```text
test/benchmark/kwok/results/kwok-compare-<timestamp>.tsv
```

The script prints a markdown table containing:

- `nodes_seen`: nodes observed by apiserver
- `pods_running`: number of pods reaching `Running`
- `time_ms`: time from workload apply to `pods_running >= pods_target` (or timeout)
- `pods/s`: `pods_running / time_ms`
- `status`: `ok` or `timeout`

## Useful Parameters

Run with default large load:

```bash
FAKE_NODES=100 PODS=10000 make bench-kwok-compare
```

Quick smoke run:

```bash
FAKE_NODES=20 PODS=400 BENCH_NAMESPACE=kwok-smoke TIMEOUT_SECONDS=600 make bench-kwok-compare
```

Keep clusters for debugging:

```bash
KEEP_CLUSTERS=true make bench-kwok-compare
```

Use pre-built KubeBrain binary:

```bash
SKIP_BUILD=true make bench-kwok-compare
```

## Notes

- Keep all parameters fixed between `etcd` and `kubebrain` runs.
- Run on an idle machine; avoid other CPU/memory-heavy workloads.
- For stable conclusions, run multiple rounds and compare medians.
