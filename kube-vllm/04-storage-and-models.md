# 04 - Storage & Model Management

Cold-start is a production SLO. This doc covers where weights live, how they get there, and the
part most guides skip: how to make a 140GB model *load in under a minute* instead of eight.

## The three problems

1. **Where** to store weights in the cluster (and at what $/GB and IOPS).
2. **How** to populate that store (download once, not per-pod).
3. **How fast** the bytes get from store -> GPU VRAM on pod start (the cold-start tax).

Problem 3 is the one that bites in production: every scale-up, every node failure, every rollout
pays the load cost. A 70B model that takes 8 minutes to load means your autoscaler is 8 minutes
behind demand.

**Architect tip:** model load time *is* your effective scale-up latency. Capacity planning
that assumes instant replicas is wrong by minutes. To meet a tight SLO you either keep warm
headroom (doc 10) or invest in fast loading. Nothing else gets you there.

---

## Storage option decision matrix

| Option | Throughput | Multi-reader | Cold-start | Cost | Use when |
|---|---|---|---|---|---|
| **Shared FS (NFS/EFS/Filestore)** | medium | yes RWX | medium | $$ | Many replicas, simple ops |
| **Parallel FS (Lustre/GPFS/FSx)** | very high | yes | fast | $$$ | Large models, many nodes |
| **Node-local NVMe** | highest | no one node | fastest (warm) | $ | Pinned single-node, cache tier |
| **Object store (S3/GCS) + stream** | high (parallel) | yes | fast w/ streamer | $ | Cloud-native, scale-to-zero |
| **OCI image / modelcar** | high | yes | fast (registry cache) | $ | Immutable, GitOps-friendly |

---

## Option 1 - Shared filesystem (the common default)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: model-pvc, namespace: llm }
spec:
  accessModes: ["ReadWriteMany"]        # or ReadOnlyMany once populated
  storageClassName: nfs
  resources: { requests: { storage: 500Gi } }
```
Mount read-only in the engine (weights are never written by vLLM):
```yaml
volumeMounts:
  - { name: model-storage, mountPath: /models, readOnly: true }
volumes:
  - { name: model-storage, persistentVolumeClaim: { claimName: model-pvc } }
```

**Senior DevOps tip:** NFS throughput, not the GPU, is often the cold-start bottleneck - 20
pods loading a 140GB model simultaneously from one NFS export will thunder-herd the filer and
serialize. Measure the filer's aggregate read bandwidth, divide by replica count, and if you land
below ~1GB/s/pod your loads will crawl. Parallel FS or a per-node NVMe cache fixes it.

---

## Option 2 - Object storage + fast streaming (the modern cloud path)

Skip the `aws s3 sync` of 140GB to local disk followed by a separate load step. That pays the
wait twice. Stream weights **directly into VRAM** with the **Run:ai Model Streamer** (built into
vLLM):

```yaml
args:
  - --model=s3://my-models/Meta-Llama-3.1-70B-Instruct
  - --load-format=runai_streamer            # concurrent S3 -> GPU streaming
  - --tensor-parallel-size=4
env:
  - { name: AWS_REGION, value: eu-west-1 }
  - name: AWS_ACCESS_KEY_ID
    valueFrom: { secretKeyRef: { name: s3-creds, key: access-key } }
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom: { secretKeyRef: { name: s3-creds, key: secret-key } }
  - name: RUNAI_STREAMER_CONCURRENCY        # tune parallelism to bucket bandwidth
    value: "16"
```

Or pre-serialize with **tensorizer** for the fastest possible load (single contiguous,
zero-copy-ish deserialization straight to GPU):
```yaml
args:
  - --model=s3://my-models/llama-70b-tensorized
  - --load-format=tensorizer
```

**Senior Dev tip:** the load bottleneck on safetensors is many-small-reads + dtype
conversion. `runai_streamer` parallelizes the reads; `tensorizer` removes the conversion by
pre-laying-out the tensors. On fast object storage either can take a 70B load from ~6-8 min to
~1 min. Benchmark both against *your* storage - results are bandwidth-dependent.

---

## Option 3 - OCI image / modelcar (immutable, GitOps-native)

Bake (or sidecar) the model as an OCI artifact so it ships through your registry like any image - 
versioned, signed, cached on nodes by the kubelet:

```yaml
# "modelcar" pattern: model as a read-only image, mounted via a native sidecar / image volume
spec:
  containers:
    - name: vllm
      image: vllm/vllm-openai:v0.9.2
      args: ["--model=/models/llama3-8b"]
      volumeMounts: [{ name: model, mountPath: /models, readOnly: true }]
  volumes:
    - name: model
      image:                                   # Kubernetes native image volume (k8s 1.31+)
        reference: registry.internal/models/llama3-8b:1.0.0
        pullPolicy: IfNotPresent
```

**Architect tip:** modelcars make the model a *versioned, signable artifact* - the same supply
chain controls (Cosign, admission policy) you apply to code now apply to weights (doc 12). For a
regulated FinTech/anti-fraud context, "which exact weights served this decision" becomes an
image digest in an audit log instead of a mutable path on a filer. That traceability is worth the
registry storage.

---

## Populating the store once - a download Job

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: download-llama3-70b, namespace: llm }
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: downloader
          image: python:3.11-slim
          command: ["/bin/sh","-c"]
          args:
            - |
              pip install -q "huggingface_hub[hf_transfer]"
              export HF_HUB_ENABLE_HF_TRANSFER=1          # parallel, fast download
              python - <<'PY'
              from huggingface_hub import snapshot_download
              snapshot_download(
                repo_id="meta-llama/Meta-Llama-3.1-70B-Instruct",
                local_dir="/models/Meta-Llama-3.1-70B-Instruct",
                max_workers=16,
              )
              PY
          env:
            - { name: HF_TOKEN, valueFrom: { secretKeyRef: { name: hf-token, key: token } } }
          volumeMounts: [{ name: model-storage, mountPath: /models }]
          resources: { requests: { cpu: "8", memory: "16Gi" }, limits: { cpu: "16", memory: "32Gi" } }
      volumes:
        - { name: model-storage, persistentVolumeClaim: { claimName: model-pvc } }
```
```bash
kubectl apply -f download-job.yaml
kubectl logs -f job/download-llama3-70b -n llm
```

**Senior DevOps tip:** set `HF_HUB_ENABLE_HF_TRANSFER=1` (the Rust-based parallel downloader)
 - it's often 3-5× faster than the default Python client and turns a 30-minute pull into single
digits. Run downloads on a **CPU node pool**, never on a tainted GPU node - you don't want a
$30/hr H100 sitting idle downloading.

---

## Access modes - the part people get wrong

| Mode | Multi-node read | Write | LLM use |
|---|---|---|---|
| `ReadWriteOnce` (RWO) | one node | yes | single-replica, local NVMe |
| `ReadOnlyMany` (ROX) | all nodes | no | **serving weights** (ideal) |
| `ReadWriteMany` (RWX) | all nodes | yes | populating + shared cache |

Pattern: populate with **RWX**, then serve with **ROX** (or RWX mounted `readOnly: true`). A
read-only mount is also a small but real defense - nothing in the serving path can corrupt weights.

---

## `/dev/shm` for tensor parallelism (recap from doc 03, because it's the #1 footfun)

```yaml
volumes:
  - { name: shm, emptyDir: { medium: Memory, sizeLimit: "32Gi" } }
volumeMounts:
  - { name: shm, mountPath: /dev/shm }
```
Multi-GPU vLLM uses `/dev/shm` for inter-process comms. Default container shm is 64MB -> TP hangs.
Size it to several GB per GPU.

---

## Quantized & pre-converted weights - storage + VRAM savings

| Format | Size vs bf16 | Speed | Quality | Notes |
|---|---|---|---|---|
| bf16 | 1× | baseline | reference | default |
| FP8 (`compressed-tensors`/native) | ~0.5× | = or faster | ~lossless | needs sm_90+ (Hopper/Blackwell) |
| AWQ (4-bit) | ~0.25× | slightly slower | minimal loss | broad GPU support |
| GPTQ (4-bit) | ~0.25× | slightly slower | minimal loss | broad GPU support |

Prefer publisher-provided or your own calibrated quants; download the `-FP8`/`-AWQ` repo variant
and point `--model`/`--quantization` at it (doc 03).

---

## Multi-model layout on one PVC

```
model-pvc (500Gi, RWX)
├── Meta-Llama-3.1-8B-Instruct/
├── Meta-Llama-3.1-70B-Instruct-FP8/
├── mistralai--Mistral-7B-Instruct-v0.3/
└── hf-cache/                       # HF_HOME for any on-demand pulls
```
Each Deployment mounts the same PVC, points `--model` at its own subdir. Keeps one storage object
to manage; isolate tenants by namespace + separate PVCs if you need hard separation (doc 12).

---

## Storage sizing reference

| Model | bf16 | FP8 | AWQ 4-bit |
|---|---|---|---|
| 8B | ~16GB | ~8GB | ~5GB |
| 34B | ~68GB | ~34GB | ~19GB |
| 70B | ~140GB | ~70GB | ~38GB |
| Mixtral 8x7B | ~90GB | ~45GB | ~26GB |
| 405B | ~810GB | ~405GB | ~210GB |

Add ~20% for tokenizer, config, and HF cache metadata. Size the PVC for *all* models you'll host
plus one in-flight download.

-> Next: [05 - Operations & Monitoring](05-operations-monitoring.md) - now keep it healthy and observable.
