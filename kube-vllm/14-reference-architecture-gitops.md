# 14 - Reference Architecture & GitOps

This is the capstone. Everything from docs 01-13 comes together here into one coherent, declaratively-managed platform: the full blueprint, the layer-by-layer component choices, Helm/Argo CD packaging, environment promotion, and the decision matrices that tell a new team what to pick.

## The full production blueprint

```
┌──────────────────────────────────────────────────────────────────────────┐
│ CLIENTS  apps · agents · RAG/GraphRAG pipelines · batch jobs               │
└───────────────────────────────┬──────────────────────────────────────────┘
                                 │ OpenAI-compatible HTTPS
┌────────────────────────────────▼─────────────────────────────────────────┐
│ EDGE / GATEWAY              (doc 09, 12)                                    │
│  Gateway API + Inference Extension (InferencePool + EPP)                    │
│  • authN/Z (OIDC/JWT/mTLS)  • token-budget rate limit  • body-based model   │
│    routing  • KV/prefix-aware load balancing  • canary weights (doc 11)     │
└──────────────┬───────────────────────────────┬───────────────────────────┘
   small/cheap │                                │ large/distributed
┌──────────────▼─────────┐         ┌────────────▼──────────────────────────┐
│ SERVING - single node  │         │ SERVING - multi-node                   │
│ (doc 03)               │         │ LeaderWorkerSet (doc 08) or            │
│ vLLM Deployment        │         │ RayService (doc 07)                    │
│ HPA/KEDA on queue (10) │         │ gang-scheduled (Kueue), topology-aware │
│ 8B FP8 · L40S/A100     │         │ 70B/405B · TP+PP+EP · NVLink/RDMA       │
└──────────────┬─────────┘         └────────────┬──────────────────────────┘
               └───────────────┬────────────────┘
┌──────────────────────────────▼───────────────────────────────────────────┐
│ PLATFORM SUBSTRATE         (docs 01, 02, 04)                                │
│  GPU Operator (driver/toolkit/DCGM/MIG/GFD) · DRA-ready · model store       │
│  (PVC/object+streamer/modelcar) · Network Operator (RDMA) · External Secrets│
└──────────────────────────────┬───────────────────────────────────────────┘
┌──────────────────────────────▼───────────────────────────────────────────┐
│ OBSERVABILITY & POLICY     (docs 05, 11, 12, 13)                            │
│  Prometheus · Grafana · DCGM · OTel traces · alerts/SLOs · Kyverno · PDBs   │
│  · PriorityClasses · ResourceQuota · NetworkPolicy                          │
└──────────────────────────────┬───────────────────────────────────────────┘
┌──────────────────────────────▼───────────────────────────────────────────┐
│ GITOPS CONTROL PLANE       (this doc)                                       │
│  Git = source of truth  ->  Argo CD  ->  every layer above, by sync wave      │
└──────────────────────────────────────────────────────────────────────────┘
```

**Architect tip:** the platform's value is the **paved road**: a product team should onboard a
model by submitting *one small values file* (model, size tier, SLO class, tenant), and get - for free
 - the right serving topology, autoscaling, routing, auth, dashboards, alerts, and rollout safety.
If onboarding a model requires understanding docs 01-13, you've built a toolkit, not a platform.
Everything below exists to collapse that complexity into one declarative interface.

---

## Component choices, by layer (the cheat sheet)

| Layer | Default choice | Reach for instead when... |
|---|---|---|
| GPU lifecycle | GPU Operator (doc 02) | bare-metal hardened image -> `driver.enabled=false` |
| GPU sharing | exclusive / MIG (doc 01) | dev/bursty -> time-slicing; future -> DRA |
| Single-node serve | vLLM Deployment + KEDA (03/10) | - |
| Multi-node serve | **LeaderWorkerSet** (doc 08) | need Serve features -> RayService (07) |
| Scheduling | Kueue gang + topology (08) | - |
| Model store | object + runai_streamer / modelcar (04) | simple/on-prem -> NFS; huge/many-node -> parallel FS |
| Gateway/routing | Gateway API Inference Extension (09) | all-vLLM, no mesh -> Production Stack router |
| Autoscale signal | queue depth via KEDA (05/10) | - |
| Secrets | External Secrets + Vault (12) | - |
| Policy/admission | Kyverno (signatures, PSS) (12) | - |
| Observability | kube-prometheus-stack + DCGM + OTel (05/13) | - |
| Delivery | Argo CD (this doc) | Flux if you're a Flux shop |

---

## GitOps: everything is a commit

Repo layout that scales from one model to a fleet:

```
llm-platform/
├── versions.yaml                  # the coupled version tuple (README matrix) - single source
├── platform/                      # cluster-wide, rarely changes
│   ├── gpu-operator/              # Helm values (driver branch, MIG, DCGM)
│   ├── network-operator/          # RDMA
│   ├── kueue/                     # cohorts, quotas, topology
│   ├── gateway/                   # Gateway + GIE install
│   ├── monitoring/                # prometheus, grafana dashboards, alert rules
│   └── policy/                    # Kyverno, PSS, NetworkPolicy baselines
├── models/                        # one file per served model - the paved-road interface
│   ├── llama3-8b.yaml             # {tier: small, slo: interactive, tenant: shared}
│   ├── llama-70b.yaml             # {tier: large, topology: single-node-fp8}
│   └── llama-405b.yaml            # {tier: xlarge, topology: lws-multinode}
├── environments/
│   ├── dev/                       # overlays: scale-to-zero, smaller SKUs
│   ├── staging/                   # overlays: prod-like, canary target
│   └── prod/                      # overlays: warm floors, reserved nodes, strict PDB
└── argocd/
    └── app-of-apps.yaml           # root Argo app -> all of the above
```

A model's values file is the *entire* interface a product team touches:
```yaml
# models/llama-70b.yaml - the paved-road abstraction
model:
  id: llama-70b
  source: registry.internal/models/llama-3.1-70b-fp8:1.2.0   # signed, immutable digest (doc 12)
  tier: large                  # -> a Helm template picks topology, SKU, probes, resources
  precision: fp8
slo:
  class: interactive           # -> TTFT p95 < 1s pool tuning + alerts (doc 13)
tenant: research               # -> namespace, quota, NetworkPolicy, rate limits (doc 12)
autoscaling:
  min: 2                       # warm floor (doc 10)
  max: 6
rollout:
  strategy: canary             # -> gateway weight steps + eval gate (doc 11)
```

**Senior DevOps tip:** put the coupled version tuple in one `versions.yaml` (vLLM <-> CUDA <->
driver <-> Ray <-> NCCL - README matrix) and template every component off it. The single worst LLM-infra
outage class is a partial upgrade where the engine image's CUDA outran the node driver. One file, one
PR, one CI gate that bumps the whole set together - never let these versions drift independently
across manifests. This one discipline prevents most multi-node "it just hangs" incidents.

---

## Argo CD: app-of-apps with sync waves (ordering matters)

GPU serving has hard ordering: the Operator must make nodes GPU-ready *before* engines schedule
(doc 02). Encode it with sync waves:

```yaml
# argocd/app-of-apps.yaml (excerpt)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gpu-operator
  annotations: { argocd.argoproj.io/sync-wave: "0" }    # substrate first
spec: { source: { path: platform/gpu-operator }, ... }
---
metadata:
  name: monitoring
  annotations: { argocd.argoproj.io/sync-wave: "1" }
---
metadata:
  name: gateway
  annotations: { argocd.argoproj.io/sync-wave: "2" }
---
metadata:
  name: models
  annotations: { argocd.argoproj.io/sync-wave: "3" }    # engines last - nodes are ready
```

**Senior DevOps tip: sync waves solve the bootstrap race - but also add a health check** so
wave 3 (models) doesn't start until the GPU Operator's `nvidia-operator-validator` is actually Ready
(doc 02), not just "Application Synced". Argo "Synced" means manifests applied, not "GPUs work". A
custom health check on the validator (or a sync hook that waits for it) is what makes the ordering
real instead of merely declared.

---

## Environment promotion

```
dev (scale-to-zero, L4/L40S, latest)  ->  staging (prod-like, canary, eval gates)  ->  prod (warm, reserved, strict)
         ▲ same base manifests, environment overlays only - promote by merging a values bump
```

**Architect tip:** promote the **exact artifact**, not a rebuild. The model image digest and
engine version that passed benchmarks (doc 13) and eval gates (doc 11) in staging are the *same
digests* that go to prod. Promotion is a one-line values-file bump, reviewed and merged. A fresh
build could differ, so you never do one. For a regulated decision system, "the thing we tested is byte-for-byte
the thing in prod" is an audit requirement, and immutable digests + GitOps make it provable from the
commit history alone.

---

## The "are we production-grade?" master checklist

**Substrate**
- [ ] GPU Operator pinned; driver branch pinned; validator gated (02)
- [ ] Sharing strategy per node pool; DRA-ready abstraction (01)
- [ ] RDMA proven with `ib_write_bw` if multi-node (06)
- [ ] Models pre-staged; cold-start measured; fast loader for big models (04)

**Serving**
- [ ] `vllm serve`, V1 engine, FP8 where it pays, right `max-model-len` (03)
- [ ] Multi-node via LWS/RayService, gang-scheduled, topology-aware (07/08)
- [ ] `startupProbe` + tight readiness + patient liveness (03)

**Traffic**
- [ ] Single gateway front door; KV/prefix-aware routing (09)
- [ ] AuthN/Z, mTLS, token-budget rate limits at the gateway (12)

**Scale & cost**
- [ ] KEDA on queue depth; asymmetric scaling; warm floor (05/10)
- [ ] Capacity derived from benchmarks; cost-per-1M-tokens published (10/13)
- [ ] Three-layer fleet (reserved/on-demand/spot) where it fits (10)

**Reliability**
- [ ] ≥2 replicas; PDB `replicas−1`; anti-affinity; AZ strategy (11)
- [ ] XID alert -> auto-cordon; synthetic correctness probe (05/11)
- [ ] Canary/blue-green model rollouts gated on eval + perf (11/13)

**Observability & policy**
- [ ] vLLM + DCGM + traces scraped; SLOs + alerts per workload class (05/13)
- [ ] NetworkPolicy default-deny; signed images; secrets externalized (12)

**Delivery**
- [ ] All of the above in Git; Argo CD app-of-apps with sync waves (this doc)
- [ ] Coupled `versions.yaml`; promote-by-digest; CI perf+eval gates

---

## Where to go from here

This series covers self-hosted vLLM on Kubernetes end to end. Natural next investments, in rough
priority for a maturing platform:

1. Disaggregated prefill/decode at scale (doc 09) once TTFT under load is your proven bottleneck.
2. **LMCache / cross-replica KV sharing** (doc 09) to push effective capacity further.
3. **Multi-cluster / multi-region** serving for residency and global latency (extends doc 11).
4. **A model gateway abstraction** that fronts *both* self-hosted and external API models behind one
 OpenAI endpoint - so product teams don't care where a model runs, and you can shift traffic
 between self-hosted and managed on cost/quality (extends doc 09).

**Architect tip: the end state isn't "we run vLLM well" - it's "model serving is a utility our
product teams consume without thinking about GPUs**". You know you're there when onboarding a model is a reviewed one-file
PR, cost-per-token lives on a dashboard, a bad rollout auto-rolls-back on an eval gate, and the whole
thing reconstructs from `git clone` + Argo CD. The infrastructure
should be the boring, reliable part. The interesting work moves up to the models and the products.
