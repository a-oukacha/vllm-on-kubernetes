# Production-Grade LLM Serving on Kubernetes - vLLM + Ray Distributed

A deep, **current** (2026) walkthrough series for running large language models in
production on Kubernetes: GPU plumbing -> single-node vLLM -> multi-node distributed
serving with Ray / LeaderWorkerSet -> gateway, autoscaling, reliability, security,
benchmarking, and a full GitOps reference architecture.

This is written for engineers who already know Kubernetes and want the *production*
decisions, not a hello-world. Every doc carries three tiers of field notes:

| Tier | Audience | Focus |
|---|---|---|
| **Senior Dev tip** | Application / model engineers | Engine flags, model behavior, request shaping, KV cache |
| **Senior DevOps tip** | Platform / SRE | Scheduling, rollout, failure modes, observability, cost |
| **Architect tip** | Staff / principal | Trade-offs, topology, capacity, org boundaries, build-vs-buy |

---

## Reading order

**Part A - Foundations (single node)**
1. [`01-gpu-k8s-fundamentals.md`](01-gpu-k8s-fundamentals.md) - Device plugin, CDI, MIG/MPS/time-slicing/**DRA**, taints, topology
2. [`02-gpu-operator.md`](02-gpu-operator.md) - GPU Operator, ClusterPolicy, DCGM, GFD/NFD, driver strategy
3. [`03-vllm-deployment.md`](03-vllm-deployment.md) - `vllm serve`, the **V1 engine**, modern flags, probes, sizing
4. [`04-storage-and-models.md`](04-storage-and-models.md) - PVC strategies, fast model loading (streamer/tensorizer), OCI modelcars
5. [`05-operations-monitoring.md`](05-operations-monitoring.md) - vLLM V1 metrics, DCGM, Prometheus/Grafana, KEDA basics

**Part B - Distributed & production**
6. [`06-distributed-inference.md`](06-distributed-inference.md) - TP/PP/EP/DP, interconnect, RDMA - the concepts
7. [`07-rayservice-production-serving.md`](07-rayservice-production-serving.md) - **KubeRay RayService + Ray Serve LLM**, GCS fault tolerance, zero-downtime upgrades
8. [`08-leaderworkerset-multinode.md`](08-leaderworkerset-multinode.md) - **LeaderWorkerSet**: native multi-node, gang scheduling, the modern alternative to raw KubeRay
9. [`09-llm-gateway-routing.md`](09-llm-gateway-routing.md) - **Gateway API Inference Extension**, KV/prefix-aware routing, disaggregated prefill/decode
10. [`10-autoscaling-capacity-cost.md`](10-autoscaling-capacity-cost.md) - KEDA/HPA on LLM signals, scale-to-zero, capacity math, spot & cost
11. [`11-reliability-rollouts.md`](11-reliability-rollouts.md) - PDBs, GPU failure, multi-AZ, canary/blue-green model rollouts
12. [`12-security-multitenancy.md`](12-security-multitenancy.md) - NetworkPolicy, authn/z, mTLS, namespace isolation, supply chain
13. [`13-benchmarking-observability.md`](13-benchmarking-observability.md) - `vllm bench`/GuideLLM, SLOs, golden signals, tracing, alerts
14. [`14-reference-architecture-gitops.md`](14-reference-architecture-gitops.md) - The full blueprint, Helm + Argo CD, environment promotion

---

## Version matrix (what "current" means here)

These docs target the following as of **mid-2026**. Pin your own versions - never ship `:latest`.

| Component | Target | Notes |
|---|---|---|
| Kubernetes | 1.31-1.33 | DRA is beta from 1.32; gang scheduling needs 1.27+ |
| vLLM | ≥ 0.9 (V1 engine default) | `vllm serve` CLI; chunked prefill + prefix caching on by default |
| NVIDIA GPU Operator | ≥ 24.9 | Driver branches 550 / 570; DCGM 3.x |
| KubeRay | ≥ 1.3 | RayService `serveConfigV2`, in-tree autoscaler, GCS FT |
| Ray | ≥ 2.40 | `ray.serve.llm` (`build_openai_app`) |
| LeaderWorkerSet (LWS) | ≥ 0.5 | `leaderworkerset.x-k8s.io/v1` |
| Gateway API Inference Extension | v1 (`InferencePool`) | Endpoint Picker (EPP), body-based routing |
| KEDA | ≥ 2.14 | Prometheus scaler for queue-depth autoscaling |

**Architect tip:** treat each of these versions as a coupled set. vLLM <-> CUDA <-> driver <->
NCCL compatibility is the #1 source of silent multi-node failures. Record the exact tuple in
a `versions.yaml` in your GitOps repo and gate upgrades through one PR that bumps the whole set.

---

## The one-page mental model

```
        ┌────────────────────────────────────────────────────────────┐
        │  Clients (apps, agents, RAG pipelines)                      │
        └───────────────┬────────────────────────────────────────────┘
                        │  OpenAI-compatible HTTP
        ┌───────────────▼────────────────────────────────────────────┐
        │  LLM Gateway  (Gateway API Inference Extension / EPP)       │  <- doc 09
        │  auth · rate limit · model routing · KV/prefix-aware LB     │
        └───────────────┬────────────────────────────────────────────┘
            ┌───────────┴───────────┬───────────────────────┐
        ┌───▼────┐              ┌───▼────┐              ┌────▼────┐
        │ vLLM   │   replicas   │ vLLM   │   …          │ RayServe│   <- docs 03/07/08
        │ 8B     │ (HPA/KEDA)   │ 70B TP4│              │ 405B    │
        └───┬────┘              └───┬────┘              └────┬────┘
            │                       │                        │
        ┌───▼───────────────────────▼────────────────────────▼───┐
        │  GPU nodes  (Operator · MIG/DRA · NVLink/RDMA · DCGM)   │  <- docs 01/02/06
        └─────────────────────────────────────────────────────────┘
                        │ metrics
        ┌───────────────▼────────────────────────────────────────────┐
        │  Prometheus · Grafana · alerts · traces (docs 05/13)        │
        └─────────────────────────────────────────────────────────────┘
        Everything above is GitOps-managed (Argo CD) - doc 14
```

If you read nothing else: **a model that fits one GPU is a Deployment problem; a model that
needs many GPUs is a *scheduling and networking* problem.** Docs 06-08 are where that line is.
