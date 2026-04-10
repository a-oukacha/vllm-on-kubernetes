# 06 - Distributed Inference: The Concepts

Splitting one model across many GPUs and nodes is its own discipline. This doc covers the *why*
and *how* - parallelism strategies, interconnect, and the math behind both. It stays at the
concept level; the production deployment patterns live in
[07 RayService](07-rayservice-production-serving.md) and
[08 LeaderWorkerSet](08-leaderworkerset-multinode.md). Read this first so those make sense.

## When you actually need this

```
Model fits on 1 GPU?            -> plain Deployment, no parallelism            (doc 03)
Model fits on 1 node (≤8 GPU)?  -> Deployment + --tensor-parallel-size N       (doc 03)
Model needs 2+ nodes?           -> RayService (07) or LeaderWorkerSet (08)
MoE model (Mixtral/DeepSeek)?   -> add expert/data parallelism (below)
```

Single-node limits that force you multi-node:
- Max 8 GPUs per typical SXM node -> 8×H100 80GB = 640GB. A 405B model in bf16 is ~810GB.
- You have many 2-4 GPU boxes instead of one 8-GPU box.
- You want more aggregate KV cache (concurrency) than one node's VRAM allows.

**Architect tip:** multi-node inference roughly *doubles* your operational complexity (gang
scheduling, RDMA, NCCL tuning, correlated failure). Before committing, exhaust the single-node
options: FP8 weights + FP8 KV cache can halve a model's footprint and keep a 70B - even a 405B at
FP8 (~405GB) - inside one 8×H100 node. **The cheapest distributed cluster is the one you didn't
need.**

---

## The four parallelism axes

### Tensor Parallelism (TP) - split each matrix
Every weight matrix is sharded across GPUs; all GPUs collaborate on **every layer**.
- Communicates at every forward step -> needs **NVLink** (intra-node) or **RDMA** (inter-node).
- `--tensor-parallel-size = GPUs that share a fast link`. Keep TP *within* an NVLink island.

### Pipeline Parallelism (PP) - split the layers
GPU/node 1 runs layers 0-19, node 2 runs 20-39, etc. Activations pass at **stage boundaries only**.
- Tolerates slower links (even Ethernet) - far less chatty than TP.
- Introduces **pipeline bubbles** (idle GPUs waiting for the previous stage) -> lower utilization.
- `--pipeline-parallel-size = number of nodes/stages`.

### Expert Parallelism (EP) - split the experts (MoE only)
For Mixture-of-Experts models (Mixtral, DeepSeek), distribute the *experts* across GPUs so each
holds a subset. Only the routed experts run per token.
- `--enable-expert-parallel` (often combined with TP/DP).

### Data Parallelism (DP) - replicate, especially for attention
Run multiple model replicas that share request load; in modern vLLM, **data-parallel attention**
replicates the attention layers across DP ranks while experts use EP - the standard layout for
large MoE serving.
- `--data-parallel-size N` (Ray Serve exposes `build_dp_openai_app`, see doc 07).

**Senior Dev tip:** the canonical large-MoE recipe is **TP within a node + EP across the
expert dimension + DP for attention**. Naïve TP across everything drowns in all-reduce traffic once
you span many nodes. Match the parallelism axis to *what the model does*: dense models -> TP (+PP
across nodes); MoE -> TP+EP(+DP).

---

## Combining axes

```bash
# 70B dense across 2 nodes of 4 GPUs each, RDMA between nodes:
vllm serve /models/Llama-3.1-70B-Instruct \
  --tensor-parallel-size 4 \        # 4 NVLinked GPUs per node share weights
  --pipeline-parallel-size 2 \      # 2 nodes form a pipeline
  --distributed-executor-backend ray
# total GPUs = TP × PP = 4 × 2 = 8
```

**Senior Dev tip:** `--distributed-executor-backend ray` is what makes vLLM span nodes; the
default (`mp`, multiprocessing) is single-node only. The Ray backend is why docs 07/08 both end up
running a Ray cluster under the hood - even LeaderWorkerSet's multi-node script bootstraps Ray.

---

## Interconnect is the whole game

| Interconnect | Bandwidth | Good for |
|---|---|---|
| NVLink / NVSwitch (intra-node) | 600-900 GB/s | TP within a node (always prefer) |
| InfiniBand NDR/HDR | 400 / 200 Gb/s | TP **and** PP across nodes |
| RoCE v2 (RDMA over Ethernet) | 100-400 Gb/s | TP/PP across nodes |
| Regular Ethernet 25-100GbE | 3-12 GB/s | **PP only** - TP across this is a disaster |

**Rule:** TP only over NVLink or RDMA. PP can tolerate Ethernet (with bubble cost). Putting TP
across plain Ethernet turns a fast model into a slideshow - the all-reduce at every layer
saturates the link.

**Senior DevOps tip:** prove the fabric *before* you debug vLLM. A multi-node deploy that
"hangs at startup" is almost always NCCL failing to find/use RDMA, not a vLLM bug:
```bash
kubectl exec -it <pod> -- ibstat                    # IB devices present & LinkUp?
kubectl exec -it <pod-a> -- ib_write_bw             # server
kubectl exec -it <pod-b> -- ib_write_bw <pod-a-ip>  # client - measure real BW
```
If `ib_write_bw` doesn't hit near line rate, fix networking first. vLLM can't be faster than NCCL.

---

## RDMA / InfiniBand on Kubernetes

RDMA needs the **NVIDIA Network Operator** (Mellanox OFED + RDMA device plugin + SR-IOV/RoCE):
```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install network-operator nvidia/network-operator \
  --namespace network-operator --create-namespace
```
Pods then request the HCA alongside GPUs:
```yaml
resources:
  limits:
    nvidia.com/gpu: 8
    rdma/hca_shared_devices_a: 1      # name depends on your NetworkOperator config
```
And a secondary RDMA network via Multus/`k8s.v1.cni.cncf.io/networks` annotation.

**NCCL env you'll touch:**
```yaml
env:
  - { name: NCCL_DEBUG, value: "INFO" }       # verbose during bring-up; remove in steady state
  - { name: NCCL_IB_DISABLE, value: "0" }     # 0 = use InfiniBand (set 1 only as a fallback)
  - { name: NCCL_NET_GDR_LEVEL, value: "5" }  # GPUDirect RDMA aggressiveness
  - { name: NCCL_SOCKET_IFNAME, value: "eth0" }  # control-plane iface (not the RDMA one)
```

**Senior DevOps tip:** `NCCL_IB_DISABLE=1` is the classic "make the hang go away" hack - it
forces NCCL onto TCP. It *works*, and your latency will be terrible. Treat it as a diagnostic that
*confirms* RDMA is misconfigured, not a fix. Ship with IB enabled and `ib_write_bw` proven.

---

## Sizing worked example - Llama 3.1 405B

```
bf16 weights ≈ 810 GB (+ KV cache headroom)

A) 16×H100 80GB across 2 nodes  -> TP 8 × PP 2   - needs InfiniBand; balanced
B) 8×H100 80GB on 1 node, FP8   -> TP 8          - ~405GB fits; NO multi-node! best latency
C) 24×A100 80GB across 3 nodes  -> TP 8 × PP 3   - needs IB; more KV cache headroom/throughput
```

**Architect tip:** option B - FP8 on a single 8×H100 node - usually wins on latency and
operational simplicity for 405B, and it's cheaper too. The instinct to "go multi-node for the big
model" tends to cost more and break more often. Quantization is a topology decision, not just a
memory one: it can collapse a 2-node cluster into a 1-node Deployment.

---

## Choosing the deployment mechanism (07 vs 08)

Both run multi-node vLLM; they differ in philosophy:

| | **RayService** (doc 07) | **LeaderWorkerSet** (doc 08) |
|---|---|---|
| Abstraction | Ray Serve apps + autoscaling | K8s-native pod groups (leader+workers) |
| Best when | You want Serve features: autoscale, multi-app, composition, fault-tolerant GCS | You want a lean, K8s-native multi-host pod with gang scheduling |
| Upgrades | Zero-downtime via new RayCluster | Rolling update of groups |
| Complexity | Higher (Ray control plane) | Lower (just pods + a bootstrap script) |
| Ecosystem | Ray dashboard, Serve, KubeRay | Kueue/topology-aware scheduling, GIE-friendly |

**Architect tip:** default to LeaderWorkerSet for "just serve this big model across N nodes"
 - it's the leaner Kubernetes-native primitive and integrates cleanly with the inference
gateway (doc 09) and topology-aware scheduling. Reach for **RayService** when you need Ray Serve's
*application* features: autoscaling replicas, multi-model composition and request graphs, or you're
already a Ray shop. Don't run Ray's control plane just to launch one model - that's complexity you
pay for daily.

---

## Common distributed issues

| Symptom | Cause | Fix |
|---|---|---|
| Hang at startup, no error | NCCL can't init / RDMA misconfigured | `ib_write_bw`; check `NCCL_DEBUG=INFO` |
| Workers never join | GCS/bootstrap port blocked by NetworkPolicy | Allow Ray ports (6379/8265/10001) between group pods |
| NCCL timeout | IB not actually used | Verify `ibstat`, GDR level; (fallback `NCCL_IB_DISABLE=1` = TCP, slow) |
| Uneven GPU memory | Mismatched GPU SKUs across nodes | Pin same `gpu.product` via affinity |
| Low utilization, high latency | PP bubbles / TP over slow link | Rebalance TP<->PP; TP only on NVLink/RDMA |
| One node dies -> whole model down | No group-restart policy | LWS `RecreateGroupOnPodRestart` / RayService FT (07/08/11) |

-> Next: [07 - RayService Production Serving](07-rayservice-production-serving.md).
