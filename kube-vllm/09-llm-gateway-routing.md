# 09 - LLM Gateway & Routing

What sits in front of your vLLM replicas? This doc covers that traffic layer. Round-robin is the
wrong default for LLMs, and we'll see why. Then **KV/prefix-aware routing**, the **Gateway API
Inference Extension**, and **disaggregated prefill/decode** - three ways to cut latency and cost
without adding a single GPU.

## Why a normal load balancer is wrong for LLMs

A Kubernetes Service round-robins requests, which is exactly what you want for stateless web apps.
LLM serving is a different beast: it's actively harmful here, because vLLM replicas are stateful in
two ways a plain LB can't see:

1. **Prefix cache** - a replica that already processed `system prompt + RAG context` can skip its
 prefill entirely on the next request that shares that prefix. Round-robin scatters related
 requests across replicas -> cache miss every time -> wasted prefill compute and high TTFT.
2. **KV cache / load** - replicas have wildly different in-flight load and free KV cache. Round-robin
 sends a request to a saturated replica (queued, slow) while another sits half-idle.

**Architect tip:** for your workloads - RAG, GraphRAG, agentic flows with big shared system
prompts - prefix-aware routing is one of the highest-ROI changes available. Agent and RAG
traffic is dominated by a large, repeated context prefix; routing the same prefix to the same
replica turns most prefills into cache hits. It's free throughput - same GPUs, more capacity, lower
TTFT - and you get it purely by changing how you route, with the model left untouched.

---

## The standard: Gateway API Inference Extension (GIE)

GIE is the Kubernetes-SIG extension that turns a Gateway API gateway into an **inference-aware**
gateway. It adds two ideas:

- **`InferencePool`** - like a Service, but for model servers; the routable backend pool.
- **Endpoint Picker (EPP)** - an extension process the gateway consults *per request* to choose the
 best replica using **live vLLM metrics** (queue depth, KV cache usage, prefix-cache locality).

```
        Client ──HTTP──▶ Gateway (Envoy/Istio/kgateway)
                              │ ext-proc, per request
                              ▼
                       Endpoint Picker (EPP)  ──reads──▶ vLLM /metrics of each replica
                              │  "send this to replica 3 (warm prefix, low queue)"
                              ▼
                       InferencePool ──▶ vllm-replica-{1..N}
```

**Senior DevOps tip:** GIE is built on the standard **Gateway API**, so it composes with the
gateway you already run (Istio, Envoy Gateway, kgateway) rather than being a bespoke proxy. The EPP
makes routing decisions from the *same* vLLM metrics you already scrape (doc 05) - `num_requests_waiting`,
`gpu_cache_usage_perc`, prefix-cache signals. No new telemetry to invent - you just route on what's
already there.

### Install (Helm, OCI charts)

```bash
export IGW_CHART_VERSION=v1.0.0

# 1) InferencePool + EPP for your vLLM Deployment (selected by label)
helm install vllm-llama3-pool \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b \
  --set provider.name=istio \
  --version $IGW_CHART_VERSION \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool \
  -n llm

# 2) (multi-model) body-based routing: route by the "model" field in the JSON body
helm install body-based-router \
  --set provider.name=istio \
  --version $IGW_CHART_VERSION \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/body-based-routing \
  -n llm
```

### Wire a Gateway + HTTPRoute to the InferencePool

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: llm-gateway, namespace: llm }
spec:
  gatewayClassName: istio
  listeners:
    - { name: http, protocol: HTTP, port: 80 }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: llm-route, namespace: llm }
spec:
  parentRefs: [{ name: llm-gateway }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /v1 } }]
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool        # <- routes via the EPP, not a dumb Service
          name: vllm-llama3-pool
```

**Senior Dev tip:** **body-based routing** reads the OpenAI `"model": "..."` field and dispatches
to the right `InferencePool` - so one endpoint (`/v1/chat/completions`) fans out to `llama3-8b`,
`llama-70b`, `mistral-7b` pools automatically. That's the OpenAI-compatible multi-model UX clients
expect, implemented at the gateway instead of in every app.

---

## Alternative: the vLLM Production Stack router

If you don't want full Gateway API, the **vLLM Production Stack** ships a purpose-built router with
prefix- and KV-aware routing as a Helm chart - lower ceremony, vLLM-specific:

```bash
# prefix-aware routing (route shared prefixes to the same replica)
helm install vllm vllm/production-stack -f values-prefix-aware.yaml -n llm

# KV-cache-aware routing (route to the replica that already holds the relevant KV blocks)
helm install vllm vllm/production-stack -f values-kv-aware.yaml -n llm
```

It also integrates **LMCache** for cross-replica KV offload/sharing (CPU/disk/remote tiers), so a
KV block computed on one replica can be reused by another:

```yaml
servingEngineSpec:
  modelSpec:
    - lmcacheConfig:
        enabled: true
        cpuOffloadingBufferSize: "30"      # GB of CPU RAM as a KV spill tier
        kvRole: "kv_producer"
        enableNixl: true                   # NIXL for fast inter-node KV transfer
```

**Architect tip: GIE vs Production Stack is a build-vs-adopt call. GIE** is the vendor-neutral
CNCF standard - pick it if you run a Gateway API mesh and want one traffic layer for everything
(it'll outlive any single project). **Production Stack** is faster to stand up and vLLM-native with
LMCache built in - pick it if you're all-vLLM and want KV-aware routing + offload today without
adopting a service mesh. Both route on the same underlying signals; the difference is ecosystem fit.

---

## Disaggregated prefill / decode (P/D)

The frontier production technique. Prefill (compute-bound, processes the whole prompt) and decode
(memory-bandwidth-bound, generates one token at a time) have **opposite** hardware profiles. Running
both on the same GPU means they interfere - a long prefill stalls everyone's decode (TTFT spikes).

**Disaggregation** splits them onto separate pools; the KV cache computed by a prefill instance is
**transferred** to a decode instance:

```
Request ─▶ Prefill pool (few, compute-heavy GPUs) ──KV cache transfer (NIXL/Mooncake/RDMA)──▶ Decode pool (many, bandwidth GPUs) ─▶ stream tokens
```

vLLM exposes this via `--kv-transfer-config` with a KV connector:
```bash
# prefill instance (producer)
vllm serve /models/llama-70b --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_producer"}'
# decode instance (consumer)
vllm serve /models/llama-70b --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_consumer"}'
```
A small proxy ties a request's prefill -> decode together (matched by request ID + `kv_transfer_params`).

**Senior Dev tip:** disaggregation is what lets you scale prefill and decode independently - 
a chat workload with short prompts/long outputs is decode-heavy (scale decode); a RAG/summarization
workload with huge prompts/short answers is prefill-heavy (scale prefill). Same model, two knobs.
But it only pays off above a real traffic threshold and needs fast KV transport (RDMA/NIXL) - below
that, co-located prefill+decode with chunked prefill (doc 03) is simpler and just as good.

**Senior DevOps tip:** don't start here. Disaggregated P/D adds a KV-transport fabric, a proxy,
and two pools to operate - only worth it at scale where the prefill<->decode interference is a
measured SLO problem. Ship co-located + prefix-aware routing first (doc 05, this doc), prove TTFT is
*still* your bottleneck under load (doc 13), then disaggregate. Use LWS subgroups (doc 08) to keep a
P/D pair as one schedulable unit.

---

## What belongs at the gateway (besides routing)

| Concern | Why at the gateway | Doc |
|---|---|---|
| AuthN/Z (API keys, JWT, mTLS) | One enforcement point, not per-replica | 12 |
| Rate limiting / quotas (per tenant, per token) | Protect GPUs from abuse | 12 |
| Model routing (body-based) | OpenAI multi-model UX | here |
| KV/prefix-aware load balancing | Latency + throughput | here |
| Retries / timeouts / circuit breaking | Streaming-aware resilience | 11 |
| Request/response logging & tracing | Audit, debugging | 13 |

**Architect tip:** make the gateway the **single front door** for all LLM traffic. Apps should
never hit a vLLM Service directly - that scatters auth, rate limits, and routing logic into every
client and makes model changes a coordinated redeploy. One gateway = one place to enforce policy,
swap models, shift traffic for canaries (doc 11), and meter cost per tenant. This is the boundary
your platform owns.

---

## Common gateway/routing issues

| Symptom | Cause | Fix |
|---|---|---|
| TTFT high despite spare capacity | Round-robin, prefix-cache misses | Enable prefix/KV-aware routing |
| One replica hot, others idle | LB blind to load | EPP routing on queue + KV usage |
| Multi-model 404 / wrong model | No body-based routing | Install body-based-router; map model->pool |
| Streaming truncated/buffered | Gateway buffering responses | Disable buffering; streaming-aware timeouts |
| P/D requests mismatched | Proxy not correlating IDs | Same `X-Request-Id` + `kv_transfer_params` |
| EPP errors, fallback to random | EPP can't read replica metrics | Check `/metrics` reachability + RBAC |

-> Next: [10 - Autoscaling, Capacity & Cost](10-autoscaling-capacity-cost.md).
