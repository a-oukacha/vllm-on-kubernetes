# 07 - RayService: Production Distributed Serving

> **Scope:** running vLLM as a **Ray Serve** application managed by **KubeRay's RayService** CRD - 
> autoscaling, GCS fault tolerance, and zero-downtime upgrades. This is the heavyweight option
> from doc 06; use it when you want Serve's *application* features, not just "launch a big model".

## Why RayService instead of `vllm serve` in a Deployment

A plain Deployment (doc 03) and even raw KubeRay (doc 06) launch vLLM as a process. **RayService**
manages a *Ray Serve application* with a real control plane:

- **Autoscaling at the replica level** driven by ongoing-request load (not just K8s HPA).
- **Multi-application / composition** - several models, request graphs, pre/post-processing actors.
- **GCS fault tolerance** - head-node metadata survives a head restart (no full cluster wipe).
- **Zero-downtime upgrades** - KubeRay spins a new RayCluster, shifts traffic, deletes the old.

**Architect tip:** the litmus test - do you need Ray Serve's *features*, or just multi-node
execution? If it's the latter, LeaderWorkerSet (doc 08) is lighter and more K8s-native. Choose
RayService when you're composing multiple models/stages, want Serve autoscaling, or already run Ray
for training/batch and want one substrate. Running a Ray control plane "just to serve one model" is
ongoing operational tax.

---

## The modern API: `ray.serve.llm`

Ray Serve ships a first-class LLM integration - you no longer hand-write a Serve deployment around
vLLM. `ray.serve.llm:build_openai_app` builds an OpenAI-compatible app from declarative `LLMConfig`.

Python form (for understanding / local `serve run`):
```python
from ray import serve
from ray.serve.llm import LLMConfig, build_openai_app

llm_config = LLMConfig(
    model_loading_config=dict(
        model_id="llama3-70b",                          # served name (the API "model")
        model_source="/models/Meta-Llama-3.1-70B-Instruct",
    ),
    deployment_config=dict(
        autoscaling_config=dict(min_replicas=1, max_replicas=4, target_ongoing_requests=64),
        max_ongoing_requests=128,
    ),
    accelerator_type="H100",                            # schedules onto H100 GPUs
    engine_kwargs=dict(
        tensor_parallel_size=4,
        pipeline_parallel_size=2,                       # 4×2 = 8 GPUs across nodes
        gpu_memory_utilization=0.92,
        max_model_len=16384,
        enable_chunked_prefill=True,
        enable_prefix_caching=True,
        kv_cache_dtype="fp8",
    ),
)
app = build_openai_app({"llm_configs": [llm_config]})
serve.run(app, blocking=True)
```

**Senior Dev tip:** everything under `engine_kwargs` maps 1:1 to the vLLM engine args from
doc 03 - `tensor_parallel_size`, `enable_prefix_caching`, `kv_cache_dtype`, etc. So your single-node
tuning transfers directly; you're just declaring it in YAML/Python instead of CLI flags.
`target_ongoing_requests` is the autoscaling setpoint (Serve adds replicas to keep concurrency near
it); `max_ongoing_requests` is the hard per-replica cap (backpressure).

---

## RayService manifest (the production object)

This is what you actually `kubectl apply`. KubeRay reconciles the Serve config onto a managed
RayCluster.

```yaml
apiVersion: ray.io/v1
kind: RayService
metadata:
  name: vllm-llama3-70b
  namespace: llm
spec:
  # ---- upgrade behavior ----
  upgradeStrategy:
    type: NewCluster               # zero-downtime: build new cluster, shift traffic, delete old
  rayClusterDeletionDelaySeconds: 120

  # ---- the Serve application (vLLM via ray.serve.llm) ----
  serveConfigV2: |
    applications:
      - name: llm
        route_prefix: /
        import_path: ray.serve.llm:build_openai_app
        runtime_env:
          env_vars:
            HF_HUB_OFFLINE: "1"
        args:
          llm_configs:
            - model_loading_config:
                model_id: llama3-70b
                model_source: /models/Meta-Llama-3.1-70B-Instruct
              accelerator_type: H100
              deployment_config:
                autoscaling_config:
                  min_replicas: 1
                  max_replicas: 4
                  target_ongoing_requests: 64
                max_ongoing_requests: 128
              engine_kwargs:
                tensor_parallel_size: 4
                pipeline_parallel_size: 2
                gpu_memory_utilization: 0.92
                max_model_len: 16384
                enable_chunked_prefill: true
                enable_prefix_caching: true
                kv_cache_dtype: fp8

  # ---- the Ray cluster that runs it ----
  rayClusterConfig:
    rayVersion: "2.43.0"
    # GCS fault tolerance: head metadata persists to Redis (survives head restart)
    gcsFaultToleranceOptions:
      redisAddress: "redis.llm.svc.cluster.local:6379"
      redisPassword:
        valueFrom: { secretKeyRef: { name: redis-password, key: password } }

    headGroupSpec:
      rayStartParams: { num-gpus: "0" }       # keep model GPUs on workers; head is control plane
      template:
        spec:
          containers:
            - name: ray-head
              image: rayproject/ray-llm:2.43.0-py311-cu124   # Ray image WITH vLLM
              resources:
                limits:   { cpu: "8", memory: "32Gi" }
                requests: { cpu: "4", memory: "16Gi" }
              ports:
                - { containerPort: 6379, name: gcs }
                - { containerPort: 8265, name: dashboard }
                - { containerPort: 8000, name: serve }
              volumeMounts:
                - { name: model-storage, mountPath: /models, readOnly: true }
          volumes:
            - { name: model-storage, persistentVolumeClaim: { claimName: model-pvc } }

    workerGroupSpecs:
      - groupName: gpu-workers
        replicas: 2
        minReplicas: 2
        maxReplicas: 6
        rayStartParams: {}
        template:
          spec:
            tolerations:
              - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
            affinity:
              nodeAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  nodeSelectorTerms:
                    - matchExpressions:
                        - { key: nvidia.com/gpu.product, operator: In, values: ["NVIDIA-H100-80GB-HBM3"] }
            containers:
              - name: ray-worker
                image: rayproject/ray-llm:2.43.0-py311-cu124
                resources:
                  limits:   { nvidia.com/gpu: 4, cpu: "48", memory: "200Gi" }
                  requests: { nvidia.com/gpu: 4, cpu: "48", memory: "200Gi" }
                volumeMounts:
                  - { name: model-storage, mountPath: /models, readOnly: true }
                  - { name: shm, mountPath: /dev/shm }
            volumes:
              - { name: model-storage, persistentVolumeClaim: { claimName: model-pvc } }
              - { name: shm, emptyDir: { medium: Memory, sizeLimit: "32Gi" } }
```

**Senior DevOps tip:** keep `num-gpus: "0"` on the **head**. The head is the Ray control plane
(GCS, dashboard, Serve HTTP proxy) - putting model GPUs there couples a $30/hr card to your control
plane and means a head restart drops a model shard. Model GPUs belong on **workers**, which scale
independently.

**Senior Dev tip:** use a Ray image that *includes vLLM* (`rayproject/ray-llm:...`) and match
its CUDA tag to your node driver branch. Mismatched CUDA between the Ray image and the node driver
is the silent killer here - it surfaces as a NCCL/CUDA init failure deep in worker logs, not as an
obvious "version mismatch".

---

## GCS fault tolerance - why the Redis matters

Without it, the Ray **head** holds all cluster metadata in memory. Head pod dies -> the entire Ray
cluster (and your served model) is gone and must cold-start. With `gcsFaultToleranceOptions`
pointing at an external Redis, head metadata persists: the head restarts, reconnects to Redis, and
workers rejoin without a full rebuild.

```bash
# minimal Redis for GCS FT (use a managed/HA Redis in real prod)
kubectl create secret generic redis-password --from-literal=password=$(openssl rand -hex 16) -n llm
helm install redis oci://registry-1.docker.io/bitnamicharts/redis -n llm \
  --set auth.existingSecret=redis-password --set auth.existingSecretPasswordKey=password
```

**Senior DevOps tip:** GCS FT is **mandatory for production RayService**, but the Redis is now a
dependency on your serving availability - make it HA (Sentinel/cluster) or use a managed Redis. A
single-pod Redis that you "added for fault tolerance" is a new single point of failure. Don't trade
one SPOF for another.

---

## Autoscaling - two layers, don't confuse them

RayService has **two** independent autoscalers:

1. **Serve replica autoscaling** (`autoscaling_config`) - adds/removes *model replicas* based on
 `target_ongoing_requests`. This is the one you tune for traffic.
2. **Ray cluster (worker) autoscaling** (`minReplicas`/`maxReplicas` + `enableInTreeAutoscaling`) - 
 adds/removes *worker pods/nodes* to provide GPUs for those replicas.

They must be sized consistently: max Serve replicas × GPUs-per-replica ≤ max worker GPUs.

**Architect tip:** this two-layer model is RayService's power *and* its trap. The Serve
autoscaler wants a replica; the cluster autoscaler must then find/boot a GPU node (minutes - doc
04). If `maxReplicas` (Serve) exceeds what `maxReplicas` (workers) can host, requests queue forever
while Serve waits for capacity that can't arrive. Always derive Serve max from worker GPU max, and
keep warm worker headroom for the first scale step. Capacity math is in **doc 10**.

---

## Zero-downtime upgrades

`upgradeStrategy.type: NewCluster` means any change to `rayClusterConfig` (new Ray version, new
image, new model) triggers KubeRay to **stand up a fresh RayCluster, wait for it to become ready
and serve traffic, then delete the old one** after `rayClusterDeletionDelaySeconds`.

```bash
# Trigger an upgrade: edit the image/model/version, then apply. KubeRay handles the cutover.
kubectl apply -f rayservice-vllm-70b.yaml
kubectl get rayservice vllm-llama3-70b -n llm -w   # watch ActiveServiceStatus / PendingServiceStatus
```

**Senior DevOps tip:** `NewCluster` upgrades temporarily double your GPU footprint (old +
new cluster both up during cutover). For an 8-GPU model that's 16 GPUs for a few minutes - make sure
quota and the cluster autoscaler can actually provision the surge, or the upgrade silently stalls
with the new cluster stuck `Pending`. Budget the surge or schedule upgrades in a maintenance window.

---

## Operating it

```bash
# Status & which cluster is active
kubectl get rayservice -n llm
kubectl describe rayservice vllm-llama3-70b -n llm

# Ray dashboard (Serve apps, replicas, GPU placement)
kubectl port-forward -n llm svc/vllm-llama3-70b-head-svc 8265:8265
# -> http://localhost:8265  (Serve tab shows replica scaling live)

# Ray cluster health
kubectl exec -it -n llm <head-pod> -- ray status
kubectl exec -it -n llm <head-pod> -- ray list actors --filter "class_name=ServeReplica"

# Hit the OpenAI API (served via the head's Serve proxy on 8000)
kubectl port-forward -n llm svc/vllm-llama3-70b-serve-svc 8000:8000
curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"llama3-70b","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

---

## Common RayService issues

| Symptom | Cause | Fix |
|---|---|---|
| RayService stuck, new cluster `Pending` on upgrade | Surge GPUs unavailable | Add quota/headroom or window the upgrade |
| Requests queue, Serve won't scale | Worker GPU max < Serve replica need | Raise worker `maxReplicas`; check cluster autoscaler |
| Whole model gone after head restart | No GCS fault tolerance | Add `gcsFaultToleranceOptions` + Redis |
| Workers don't join | Ray ports blocked / image CUDA mismatch | Allow 6379/10001; match Ray image CUDA <-> driver |
| `serve` 503 right after apply | App still deploying (model loading) | Watch dashboard Serve tab; gate clients on readiness |
| OOM on workers under load | `gpu_memory_utilization`/`max_ongoing_requests` too high | Lower both; see doc 05 |

-> Next: [08 - LeaderWorkerSet](08-leaderworkerset-multinode.md) - the leaner, K8s-native multi-node path.
