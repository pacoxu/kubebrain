# Kind Benchmark Comparison

This benchmark compares two storage backends under the same kind + kube-apiserver setup:

- `etcd`: default kind control-plane etcd
- `kubebrain`: kube-apiserver redirected to KubeBrain (`--compatible-with-etcd=true`)

## Quick Run

```bash
make bench-kind-compare
```

Result is written to:

```text
test/benchmark/kind/results/kind-compare-<timestamp>.tsv
```

The script also prints a markdown table with:

- `ops/s`: successful operation throughput
- `avg_ms`, `p50_ms`, `p90_ms`, `p99_ms`: latency of one CRUD sequence (`create + patch + delete` on ConfigMap)

## Useful Parameters

```bash
BENCH_OPS=400 BENCH_CONCURRENCY=16 BENCH_WARMUP=40 make bench-kind-compare
```

```bash
K8S_IMAGE=m.daocloud.io/docker.io/kindest/node:v1.35.0 make bench-kind-compare
```

```bash
KEEP_CLUSTERS=true make bench-kind-compare
```

```bash
SKIP_BUILD=true make bench-kind-compare
```

## Notes

- Run on an idle machine; avoid other heavy workloads.
- Keep all benchmark parameters identical when comparing.
- Do multiple runs and compare median results, not a single run.
- If you set `KUBEBRAIN_KEY_PREFIX`, do not end it with `/`.
