# 13 - Benchmarking & Observability

Measuring an LLM serving system is its own skill. Load testing to find the real capacity curve.
Defining SLOs that map to UX. The golden signals and tracing that tell you why latency moved. Every
capacity and autoscaling number in docs 05/10 traces back to the work here. You can't size, scale, or
SLO what you haven't benchmarked.

## Why LLM benchmarking is its own skill

A web service has one latency number. An LLM has a **latency *curve* in two dimensions** (TTFT and
TPOT) that bends sharply with concurrency, prompt length, and output length. "It does 2000 tokens/sec"
is meaningless without "at what concurrency, what prompt size, within what latency SLO". The thing you
map is a surface, not a single point.

**Senior Dev tip: there are two regimes and you must benchmark both. Latency-bound** (low
concurrency, interactive): TTFT and TPOT dominate, batch is small, the GPU is underfed. **Throughput-
bound** (high concurrency, batch/RAG): the batch is full, tokens/sec/GPU is maximized but per-request
latency climbs. The same replica looks like two different machines. Your SLO lives in one regime;
benchmark *that* one at *your* token mix.

---

## The metrics vocabulary (get these exactly right)

| Metric | Definition | What it controls |
|---|---|---|
| **TTFT** - Time To First Token | request arrival -> first token | perceived responsiveness; queue + prefill |
| **TPOT / ITL** - Time Per Output Token / Inter-Token Latency | steady-state gap between tokens | streaming smoothness; decode speed |
| **E2E latency** | arrival -> last token | = TTFT + (TPOT × output_tokens) |
| **Throughput** | total output tokens/sec across all requests | capacity / $ efficiency |
| **Goodput** | throughput of requests that *met SLO* | the only throughput that counts |
| **Concurrency** | simultaneous in-flight requests | the x-axis of every curve |

**Senior Dev tip:** optimize for **goodput**, not raw throughput. A server bragging 5000 tok/s
while half the requests blew the TTFT SLO is serving 2500 tok/s of *usable* work and a pile of angry
users. Goodput = throughput counting only SLO-compliant requests. It's the metric that aligns the
benchmark with the business. Plot goodput vs concurrency - it rises, peaks, then *falls* as overload
sets in; that peak is your per-replica capacity (`R_max` in doc 10).

---

## Load testing with the right tools

vLLM ships its own benchmark; **GuideLLM** adds SLO-oriented sweeps.

```bash
# vLLM's built-in benchmark - fixed concurrency, your token distribution
vllm bench serve \
  --backend openai \
  --base-url http://vllm-llama3-8b.llm \
  --model llama3-8b \
  --dataset-name random \
  --random-input-len 1024 --random-output-len 256 \   # MATCH your real traffic
  --max-concurrency 64 \
  --num-prompts 1000
# reports: TTFT (mean/p50/p99), TPOT, throughput, per-request latency
```

```bash
# GuideLLM - sweep concurrency to find the capacity curve & SLO cliff
guidellm benchmark \
  --target http://vllm-llama3-8b.llm \
  --model llama3-8b \
  --rate-type sweep \                                   # ramps load to find the knee
  --data '{"prompt_tokens":1024,"output_tokens":256}'
```

**Senior DevOps tip:** **benchmark on the real cluster, through the gateway, from a separate
node** - not `localhost`, not port-forward. You're measuring the production path: gateway routing
(doc 09), NetworkPolicy, mTLS overhead, real NIC. A `port-forward` benchmark measures the engine in
a vacuum and overstates capacity by ignoring everything in front of it. And benchmark *with* and
*without* prefix-aware routing - the delta is your routing ROI in hard numbers.

**Senior Dev tip:** feed the benchmark **your** input/output token distribution, sampled from
production (`vllm:request_prompt_tokens` / `:request_generation_tokens` histograms, doc 05). A
`random 1024/256` sweep is a starting point; a chat product (short in, long out) and a RAG product
(huge in, short out) have completely different capacity curves on the *same* GPU. Garbage token mix
in -> garbage capacity plan out.

---

## Defining SLOs that mean something

Map model latency to user experience, then set thresholds:

| Workload | TTFT SLO | TPOT SLO | Rationale |
|---|---|---|---|
| Interactive chat / agent | p95 < 500ms-1s | p95 < 50ms (>20 tok/s) | feels responsive, reads faster than human |
| RAG / long-context Q&A | p95 < 2-3s | p95 < 80ms | big prefill tolerated; steady stream |
| Batch / async (offline) | n/a | n/a | optimize throughput/cost, not latency |

```yaml
# Record SLI/error-budget burn as Prometheus rules
groups:
  - name: vllm-slo
    rules:
      - record: vllm:ttft:p95
        expr: histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le, model))
      - alert: TTFTSLOBreach
        expr: vllm:ttft:p95 > 1.0
        for: 10m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.model }} TTFT p95 {{ $value }}s > 1s SLO" }
```

**Architect tip:** SLO per **workload class**, not per model. A chat product and a batch
summarizer can run the *same* 70B and need wildly different SLOs - one is sub-second-TTFT-critical,
the other doesn't have a TTFT SLO at all. Tag traffic with its workload class at the gateway, route
to appropriately-tuned pools, and SLO each class. One global "LLM latency SLO" either over-provisions
the batch path or fails the interactive one. The SLO is a property of the *use case*, attached to traffic.

---

## The golden signals for LLM serving

| Signal | LLM metric(s) | Source |
|---|---|---|
| **Latency** | TTFT p50/p95/p99, TPOT, E2E | vLLM `/metrics` |
| **Traffic** | requests/sec, tokens/sec in & out | vLLM + gateway |
| **Errors** | 5xx, preemptions, OOMs, refusals | vLLM, k8s events, gateway |
| **Saturation** | queue depth, KV cache %, GPU SM_ACTIVE | vLLM + DCGM |

Overlay **queue depth × KV-cache-usage × TTFT** on one dashboard row - when TTFT rises, this trio
tells you instantly whether it's *load* (queue up -> scale, doc 10), *memory* (KV near 100% -> preemption,
tune doc 03), or *batching* (SM_ACTIVE low -> raise batched-tokens). That single correlation resolves
most latency pages without a deep dive.

---

## Distributed tracing - follow one request through the system

For multi-hop paths (gateway -> EPP -> vLLM -> tools -> back), traces show *where* the time went:
```yaml
# OpenTelemetry: vLLM can emit traces; propagate trace context from the gateway
env:
  - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.observability:4317" }
  - { name: OTEL_SERVICE_NAME, value: "vllm-llama3-8b" }
args:
  - --otlp-traces-endpoint=http://otel-collector.observability:4317
```
A trace splits E2E latency into: gateway/routing, queue wait, prefill, decode, (tool calls). When
TTFT spikes, the trace says whether it was *queue* (capacity) or *prefill* (prompt size / cache miss)
 - two completely different fixes.

**Senior DevOps tip:** propagate the **same request ID** (`X-Request-Id`) from gateway -> vLLM ->
logs -> traces. When a user reports "it was slow at 14:32", you want to pull *their exact request*
across all three systems in seconds, not grep timestamps. This is non-negotiable for disaggregated
P/D (doc 09) where one logical request spans prefill and decode pods - the request ID is the only
thread tying them together.

---

## Continuous benchmarking - catch regressions before users do

Run the benchmark in CI on every model/engine/flag change and gate on it:
```
On PR that bumps vLLM version / model / engine flags:
  1. Deploy candidate to a canary cluster
  2. vllm bench serve at your production token mix + concurrency
  3. Compare TTFT p95 / TPOT p95 / goodput vs baseline
  4. FAIL the PR if regression > threshold (e.g. TTFT +15%)
```

**Architect tip:** a vLLM upgrade can *regress* performance (a scheduler change, a default flip,
a kernel swap) even as it adds features - and you won't notice until users do. Gate engine/model
changes on a **performance benchmark in CI**, the same way you gate code on tests. Pair it with the
*quality* eval gate from doc 11 (correctness) and you have the two gates a model rollout needs:
"is it still fast?" and "is it still right?". Shipping without both is shipping blind.

-> Next: [14 - Reference Architecture & GitOps](14-reference-architecture-gitops.md) - assemble it all.
