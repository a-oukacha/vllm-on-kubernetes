# 03 - Deploying vLLM on Kubernetes

This is a single-node vLLM Deployment done the *current* way. You get the V1 engine, the `vllm serve` CLI, the flags that actually move throughput and latency, and probes that don't lie about whether the model is loaded.

## What vLLM is (and what changed)

vLLM is a high-throughput LLM inference engine. The pillars:
- **PagedAttention** - KV cache in fixed-size blocks -> near-zero memory fragmentation.
- **Continuous batching** - requests join/leave the running batch every step, no padding waste.
- **Chunked prefill + prefix caching** - long prompts don't stall decode; shared prefixes are reused.
- **OpenAI-compatible API** - `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`.

**What's current (V1 engine):** since vLLM ≈0.8 the rewritten **V1 engine** is the default. You
generally *don't* set `VLLM_USE_V1=1` anymore - it's on. V1 enables **chunked prefill and prefix
caching by default**, has a cleaner scheduler, and is the only path getting new features. Treat
"V1 default" as the baseline for everything below.

**Senior Dev tip:** the canonical entrypoint is now `vllm serve <model>`, not
`python3 -m vllm.entrypoints.openai.api_server`. The old module still works but the CLI is what
docs/flags track. Use `vllm serve` so your args match upstream examples 1:1.

---

## Single-GPU Deployment (the modern baseline)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-llama3-8b
  namespace: llm
  labels: { app: vllm-llama3-8b, model: llama3-8b }
spec:
  replicas: 1
  selector: { matchLabels: { app: vllm-llama3-8b } }
  template:
    metadata:
      labels: { app: vllm-llama3-8b, model: llama3-8b }
    spec:
      terminationGracePeriodSeconds: 120          # let in-flight requests drain
      tolerations:
        - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: nvidia.com/gpu.product, operator: In, values: ["NVIDIA-A100-SXM4-80GB","NVIDIA-H100-80GB-HBM3"] }
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.9.2
          args:
            - --model=/models/Meta-Llama-3.1-8B-Instruct
            - --served-model-name=llama3-8b
            - --host=0.0.0.0
            - --port=8000
            - --max-model-len=8192
            - --gpu-memory-utilization=0.90
            - --max-num-seqs=256
            - --enable-prefix-caching              # explicit (default on in V1, but be intentional)
          ports:
            - { containerPort: 8000, name: http }
          env:
            - { name: HF_HUB_OFFLINE, value: "1" }   # model already on PVC; don't phone home
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom: { secretKeyRef: { name: hf-token, key: token } }
            - name: VLLM_API_KEY
              valueFrom: { secretKeyRef: { name: vllm-api-key, key: key } }
          resources:
            limits:   { nvidia.com/gpu: 1, memory: "32Gi", cpu: "16" }
            requests: { nvidia.com/gpu: 1, memory: "32Gi", cpu: "16" }
          volumeMounts:
            - { name: model-storage, mountPath: /models, readOnly: true }
            - { name: shm, mountPath: /dev/shm }     # required for multi-GPU & helpful single-GPU
          startupProbe:                              # see "probes" below
            httpGet: { path: /health, port: 8000 }
            periodSeconds: 10
            failureThreshold: 60                     # up to 10 min to load a big model
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /health, port: 8000 }
            periodSeconds: 30
            failureThreshold: 3
      volumes:
        - { name: model-storage, persistentVolumeClaim: { claimName: model-pvc } }
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: "8Gi" } }
```

**Senior DevOps tip:** the `startupProbe` is the single most important change from naïve
manifests. Without it you must inflate `readinessProbe.initialDelaySeconds` to cover worst-case
model load - which then *delays liveness detection forever* once running. A `startupProbe` gives loading a long leash and then hands off to a tight readiness/liveness loop. That alone fixes most "probe killed my pod mid-load" CrashLoops.

---

## Multi-GPU on one node - Tensor Parallelism

For models that don't fit one card (70B fp16 ≈ 140GB):

```yaml
args:
  - --model=/models/Meta-Llama-3.1-70B-Instruct
  - --tensor-parallel-size=4          # split each layer across 4 GPUs
  - --max-model-len=8192
  - --gpu-memory-utilization=0.92
resources:
  limits:   { nvidia.com/gpu: 4, memory: "200Gi", cpu: "48" }
  requests: { nvidia.com/gpu: 4, memory: "200Gi", cpu: "48" }
volumes:
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: "32Gi" }   # TP uses /dev/shm heavily
```

`--tensor-parallel-size` **must equal** the GPU count, and those GPUs should share NVLink
(`nvidia-smi topo -m`). For >8 GPUs / multi-node, you stop using a plain Deployment - see docs 06-08.

**Senior Dev tip:** undersize `/dev/shm` and TP will hang or crash with cryptic NCCL/shm
errors at startup. Rule of thumb: `sizeLimit` ≥ a few GB per GPU, because the default container `/dev/shm` of 64MB is far too small. This is the #1 single-node TP footgun.

---

## The flags that actually matter (and why)

| Flag | What it does | Production guidance |
|---|---|---|
| `--gpu-memory-utilization` | Fraction of VRAM for weights + KV cache | 0.90 default; drop to 0.85 if you see OOM under load |
| `--max-model-len` | Max context (tokens) | Set to your *real* max prompt+output, not the model's theoretical max - it sizes KV cache |
| `--max-num-seqs` | Max concurrent sequences in a batch | Higher = more throughput, more VRAM; tune via benchmark (doc 13) |
| `--max-num-batched-tokens` | Token budget per scheduler step | Governs chunked-prefill granularity; raise for throughput, lower for TTFT |
| `--kv-cache-dtype fp8` | Quantize KV cache to FP8 | ~2× more KV cache (longer ctx / more concurrency) on Hopper+; tiny quality cost |
| `--quantization` | Weight quant: `fp8`, `awq`, `gptq`, `compressed-tensors` | Fit big models on fewer GPUs; FP8 needs sm_90+ |
| `--enable-prefix-caching` | Reuse shared prompt prefixes | Huge win for RAG/system-prompt-heavy & agent workloads |
| `--enable-chunked-prefill` | Interleave prefill with decode | On by default in V1; keeps TTFT stable under long prompts |
| `--speculative-config` | Speculative decoding (draft model / ngram / EAGLE) | Lower latency for low-concurrency; structured JSON config |
| `--enable-expert-parallel` | Expert parallelism for MoE | Mixtral/DeepSeek-style models - see doc 06 |
| `--dtype` | `auto`/`bfloat16`/`float16` | `auto` (bf16 on Ampere+) unless a model demands otherwise |

Speculative decoding (current structured form):
```yaml
args:
  - --model=/models/Meta-Llama-3.1-70B-Instruct
  - --tensor-parallel-size=4
  - --speculative-config={"model":"/models/Llama-3.2-1B-Instruct","num_speculative_tokens":5}
```

**Senior Dev tip:** speculative decoding trades GPU compute for latency. It shines at
**low concurrency** (an interactive assistant), but once the batch is already full at high
concurrency it can *hurt* throughput. Don't enable it blindly on a batch-heavy endpoint; A/B it with doc 13.

**Architect tip:** decide your precision strategy per *model tier*, not globally.
Frontier-quality 70B+ on H100 -> FP8 weights + FP8 KV cache buys you 2× effective capacity at
negligible quality loss. Small models where quality is fragile -> keep bf16. Encode the precision
choice in the model's deployment values and benchmark it (doc 13) before it reaches users.

---

## Exposing the service

```yaml
apiVersion: v1
kind: Service
metadata: { name: vllm-llama3-8b, namespace: llm }
spec:
  selector: { app: vllm-llama3-8b }
  ports: [{ name: http, port: 80, targetPort: 8000 }]
  type: ClusterIP
```

External access via Ingress - note the long timeouts (token streams are slow):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"     # stream tokens, don't buffer
spec:
  rules:
    - host: llm.company.internal
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: vllm-llama3-8b, port: { number: 80 } } } }
```

**Senior DevOps tip:** `proxy-buffering: off` is non-negotiable for streaming endpoints. With
buffering on, the proxy holds tokens until the buffer fills, destroying the streaming UX and
inflating perceived TTFT. For real LLM traffic management, move past Ingress to the inference
gateway in **doc 09**.

---

## Secrets - never inline tokens

```bash
kubectl create secret generic hf-token       --from-literal=token=hf_xxx -n llm
kubectl create secret generic vllm-api-key    --from-literal=key=sk-internal-xxx -n llm
```
Setting `VLLM_API_KEY` makes vLLM require `Authorization: Bearer sk-internal-xxx` on every request.

---

## Testing

```bash
kubectl port-forward svc/vllm-llama3-8b 8000:80 -n llm

curl localhost:8000/v1/models -H "Authorization: Bearer sk-internal-xxx"

curl localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer sk-internal-xxx" -H "Content-Type: application/json" \
  -d '{"model":"llama3-8b","messages":[{"role":"user","content":"ping"}],"max_tokens":16,"stream":true}'
```

---

## Probes, properly

vLLM exposes `GET /health`. The trap is conflating "process up" with "model loaded".

| Probe | Purpose | Setting |
|---|---|---|
| `startupProbe` | Cover slow model load | `failureThreshold × periodSeconds` ≥ worst-case load (70B ≈ 5-8 min) |
| `readinessProbe` | Gate traffic | tight: 10s period, 3 failures |
| `livenessProbe` | Restart a wedged engine | 30s period, 3 failures - but mind in-flight loss |

**Senior DevOps tip:** keep `livenessProbe` *conservative*. vLLM under extreme load can be
briefly unresponsive on `/health`; an aggressive liveness probe will kill a healthy-but-busy
engine and dump every in-flight request. Let readiness react fast, but give liveness plenty of patience.

---

## GPU memory sizing (rule-of-thumb)

| Model | Precision | Weights | Min fit |
|---|---|---|---|
| 8B | bf16 | ~16GB | 1× A100 40GB |
| 8B | FP8 | ~8GB | 1× L40S / any 24GB+ |
| 70B | bf16 | ~140GB | 2× A100 80GB (TP2) |
| 70B | FP8 | ~70GB | 1× H100 80GB (tight) / 2× safe |
| Mixtral 8x7B | bf16 | ~90GB | 2× A100 80GB |

**Always leave headroom for KV cache** - that's what `--gpu-memory-utilization` carves out.
Weights are fixed; KV cache scales with `max-model-len × max-num-seqs`. Under-provisioning KV
cache shows up as request *preemption*, not OOM (doc 05).

---

## Common startup failures

| Symptom | Cause | Fix |
|---|---|---|
| `CUDA out of memory` at load | Model > VRAM | Quantize, more GPUs (TP), or smaller `--max-model-len` |
| OOM only under load | KV cache too big | Lower `--gpu-memory-utilization` to 0.85, cap `--max-num-seqs` |
| `model not found` | Wrong path / PVC not mounted | Check mount + `--model` path |
| Immediate CrashLoop on gated model | Missing/invalid HF token | Check secret; or pre-download (doc 04) |
| TP hangs at startup | `/dev/shm` too small | Raise `emptyDir.sizeLimit` |
| FP8 model refuses to load | GPU < sm_90 | Pin to Hopper+ via affinity (doc 02) |
| Probe kills pod during load | No `startupProbe` | Add one with a long leash |

-> Next: [04 - Storage & Model Management](04-storage-and-models.md) - get weights onto the node *fast*.
