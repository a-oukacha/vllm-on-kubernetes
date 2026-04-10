# 10 - Autoscaling, Capacity & Cost

Cost is the thing that kills LLM platforms. How many GPUs do you actually need? How do you scale them
on the *right* signal, scale to zero without paying for idle frontier silicon, and pull the cost levers
that decide whether the platform survives? That is the ground this chapter covers.

## First principle: GPUs are the budget

A single H100 runs **$2-4/hr** on-demand (~$25-35k/yr if pinned). The dominant cost question for any
LLM platform is *"how few GPU-hours can serve the SLO?"* Everything in this doc serves that question.

**Architect tip:** an idle GPU you're renting is pure waste, so don't generate tokens on one when
something cheaper can serve them. The cost hierarchy, best to worst: (1) cache it (prefix/KV/semantic - docs 04/09), (2) route it to a
warm replica (doc 09), (3) batch it (vLLM continuous batching), (4) scale a replica up, (5) cold-boot
a new GPU node. Optimize *up* that list before you add hardware. Most "we need more GPUs" requests
are actually routing or batching problems.

---

## Capacity math you can actually do

You don't guess replica counts - you derive them from a benchmark (doc 13) and traffic.

```
Given (from a load test on ONE replica, at your SLO):
  R_max   = max requests/sec one replica sustains within TTFT+TPOT SLO
  T_in    = avg input tokens   T_out = avg output tokens

Demand:
  QPS_peak = peak requests/sec you must serve

Replicas needed:
  N = ceil( QPS_peak / R_max ) + headroom
      headroom = 1 replica (or ~20%) to absorb burst while autoscaler reacts

KV-cache concurrency check (per replica):
  concurrent_seqs ≈ (VRAM_free_for_kv) / (kv_bytes_per_token × (T_in + T_out))
  if concurrent_seqs < your needed in-flight count -> raise gpu-mem-util, FP8 KV, or more replicas
```

**Senior Dev tip:** throughput is **not** a single number - it depends on input/output token
mix. A replica that does 40 req/s of short chat does maybe 4 req/s of long-doc summarization (10×
the prefill + KV). Benchmark at *your* traffic's token distribution (doc 13), not the vendor's
"tokens/sec" headline, or your capacity model will be off by an order of magnitude.

---

## Scale on the right signal (recap + depth)

Autoscale on **queue depth**, not GPU utilization (doc 05 explains why). KEDA with the Prometheus scaler:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: vllm-scaler, namespace: llm }
spec:
  scaleTargetRef: { name: vllm-llama3-8b }
  minReplicaCount: 2                      # always-warm floor (SLO + cold-start protection)
  maxReplicaCount: 8                      # bounded by GPU quota
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:   { stabilizationWindowSeconds: 0,   policies: [{ type: Pods, value: 2, periodSeconds: 60 }] }
        scaleDown: { stabilizationWindowSeconds: 600, policies: [{ type: Pods, value: 1, periodSeconds: 120 }] }
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://monitoring-kube-prometheus-prometheus.monitoring:9090
        query: sum(vllm:num_requests_waiting{app="vllm-llama3-8b"}) / 2   # per-replica target via maxReplica scaling
        threshold: "5"
```

**Senior DevOps tip:** asymmetric scaling is the whole trick - `scaleUp` aggressive (0s
stabilization, +2 pods/min), `scaleDown` lazy (10-min window, −1 pod/2min). GPU pods cost too much
to keep, but cold-start too slowly to react late. Aggressive-up protects the SLO; lazy-down protects
the bill and prevents thrashing. Symmetric scaling is wrong in both directions for GPUs.

---

## Scale-to-zero (the big lever for spiky / dev / many-model)

Idle frontier GPUs are pure waste. KEDA can scale a Deployment to **0** and cold-start on the first
request - at the cost of that request waiting for a model load:

```yaml
spec:
  minReplicaCount: 0
  idleReplicaCount: 0
  cooldownPeriod: 1800        # 30 min idle before scaling to zero
```

The cold-start tax (doc 04) is the catch: the first request after scale-to-zero waits node-boot +
model-load (minutes). Mitigations:
- **Fast loading** (runai_streamer/tensorizer - doc 04) shrinks the model-load part.
- **Warm node pool** (node already up, just pod scheduling) shrinks the node-boot part.
- **Activator/queue** that holds the first request and returns once warm, instead of erroring.

**Architect tip:** scale-to-zero is right for **dev environments, internal tools, long-tail
models, and bursty batch** - anywhere a multi-minute first-request is acceptable. It's wrong for an
interactive production endpoint with a TTFT SLO; there you keep a warm floor (`minReplicaCount ≥ 1-2`)
and eat the idle cost as the price of the SLO. Per-model: cheap-to-keep small models stay warm;
expensive rarely-used big models scale to zero. One policy per model tier, not one policy globally.

---

## Right-sizing the model to the hardware

The biggest cost win is often per-replica right-sizing, which beats any autoscaling tweak:

| Lever | Effect | Cost impact |
|---|---|---|
| FP8 weights (Hopper+) | 70B fits 1×H100 instead of 2× | **−50% GPUs** |
| FP8 KV cache | ~2× concurrency per GPU | fewer replicas for same QPS |
| Right `max-model-len` | KV cache sized to real need, not theoretical max | more concurrency per GPU |
| Quantized (AWQ/GPTQ) small models | 8B on a cheap L4/L40S not an A100 | cheaper SKU |
| Prefix/KV-aware routing (doc 09) | fewer prefills = more effective capacity | fewer replicas |

**Senior Dev tip:** `--max-model-len` is a stealth cost lever. KV cache is sized for
`max_model_len × max_num_seqs`. If you set `max-model-len 131072` "to be safe" but real prompts are
4k, you've reserved 32× the KV cache you need and slashed your concurrency. Set it to your real p99
context length + output. Measure it from `vllm:request_prompt_tokens` (doc 05), don't guess.

---

## Cheaper GPU-hours: spot, mixed SKUs, commitments

| Tactic | Saving | Risk / mitigation |
|---|---|---|
| **Spot/preemptible GPU nodes** | 60-90% | Preemption - only for stateless replicas + PDB + fast reschedule |
| **Mixed SKU pools** (L40S for small, H100 for big) | match $ to need | affinity routing per model (doc 01/02) |
| **Committed use / reserved** | 30-60% | for the always-warm floor you'll never turn off |
| **On-demand burst on top of committed** | elastic | autoscaler adds on-demand above the reserved floor |

**Senior DevOps tip:** spot works for LLM *serving* only with care: a preempted replica drops its
in-flight requests. Use it for stateless single-replica models that scale horizontally (the
gateway just re-routes), keep a `minReplicaCount` on **on-demand/reserved** nodes as the SLO floor,
and burst to spot above it. Never put a multi-node LWS/RayService group on spot - one preempted node
recreates the whole group (docs 07/08). Spot for the scalable middle, reserved for the floor, never
for the indivisible.

**Architect tip: the canonical cost-optimal shape is a three-layer fleet**: a small
*reserved* always-warm floor (SLO guarantee), an *on-demand* autoscaling band (normal peaks), and a
*spot* overflow band (cheap burst for bulk/batch/non-SLO traffic, routed there explicitly by the
gateway). One uniform on-demand fleet is the easy choice and the expensive one.

---

## Multi-tenancy & fair sharing

When several teams share GPUs, autoscaling isn't enough - you need *admission* and *priority*:

```yaml
# Production preempts batch when GPUs are scarce
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: llm-production }
value: 1000000
preemptionPolicy: PreemptLowerPriority
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: llm-batch }
value: 1000
```
Combine with **Kueue** quotas (doc 08) for queued fair-sharing, and `ResourceQuota` (doc 05) for hard
per-namespace GPU caps.

**Architect tip:** decide your scarcity policy *before* you're scarce. When the cluster is full
and a production scale-up needs GPUs held by a batch job, what happens - does production preempt, or
wait? Encode that as PriorityClasses + Kueue cohorts now. The alternative is deciding it during an
incident, manually, under pressure, badly.

---

## Cost observability - meter what you spend

You can't optimize what you don't measure. Track:
- **GPU-hours per model** (`sum(nvidia.com/gpu) by (model)` over time).
- **Tokens per GPU-hour** (`vllm:generation_tokens_total` / GPU-hours) - your efficiency KPI.
- **Cost per 1M tokens per model** - the number finance and product care about.
- **Idle GPU-hours** (allocated but `SM_ACTIVE` low) - pure waste, the first thing to cut.

**Architect tip:** publish **cost per 1M tokens per model** as a first-class platform metric.
It turns abstract "GPU spend" into a number product teams can reason about, makes the case for FP8 /
quantization / routing investments self-evident (the number drops), and lets you compare self-hosting
vs an API provider honestly. A platform that can't state its cost-per-token can't defend its existence.

-> Next: [11 - Reliability & Rollouts](11-reliability-rollouts.md).
