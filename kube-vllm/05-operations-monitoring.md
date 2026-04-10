# 05 - Operations & Monitoring

> This is the day-2 operational core: the signals that tell you whether vLLM is healthy, fast, and
> worth its GPU bill, plus the autoscaling and graceful-shutdown mechanics that keep it that way -
> deep SLO/alerting and load testing live in **doc 13**.

## The endpoints

| Endpoint | Purpose |
|---|---|
| `GET /health` | Liveness/readiness - server up |
| `GET /v1/models` | Model loaded & served name correct |
| `GET /metrics` | Prometheus metrics (on by default) |

```bash
kubectl exec -it deploy/vllm-llama3-8b -n llm -- curl -s localhost:8000/health
kubectl exec -it deploy/vllm-llama3-8b -n llm -- curl -s localhost:8000/v1/models
```

---

## The vLLM metrics that matter (V1 engine)

vLLM exposes Prometheus metrics on `/metrics`. The ones you build dashboards and alerts on:

| Metric | What it tells you | Reaction |
|---|---|---|
| `vllm:num_requests_running` | In-flight (decoding) requests | Your live concurrency |
| `vllm:num_requests_waiting` | **Queued** requests | >0 sustained = under-provisioned -> scale (the key autoscale signal) |
| `vllm:gpu_cache_usage_perc` | KV cache utilization | Near 1.0 = memory pressure -> preemption imminent |
| `vllm:num_preemptions_total` | Requests evicted from batch | Any sustained rate = KV cache too small; lower load or `max-num-seqs` |
| `vllm:time_to_first_token_seconds` | **TTFT** histogram | Prefill/queue latency - the "responsiveness" SLI |
| `vllm:time_per_output_token_seconds` | **TPOT/ITL** histogram | Decode speed - the "how fast it types" SLI |
| `vllm:e2e_request_latency_seconds` | End-to-end latency | The user-facing SLI |
| `vllm:request_prompt_tokens` / `:request_generation_tokens` | Input/output token histograms | Traffic shape; capacity math |
| `vllm:prefix_cache_hits_total` / `:queries_total` | Prefix cache effectiveness | Low hit rate = routing not prefix-aware (doc 09) |

**Senior Dev tip: the two numbers that define LLM UX are TTFT** (how long until the first
token appears) and **TPOT/ITL** (inter-token latency - how fast it streams after that). Latency is
not one number. A model can have great TTFT and miserable TPOT (feels like it stutters) or vice
versa. Always SLO them separately (doc 13).

**Senior DevOps tip:** `num_requests_waiting` is your autoscaling truth, *not* GPU utilization.
A vLLM replica can run at 100% GPU UTIL while happily absorbing more load via batching, so scaling on
UTIL there just wastes money. Worse, a queue can build while UTIL still looks moderate. Scale on queue
depth / running-vs-capacity, and let DCGM UTIL be a *diagnostic*, not a *trigger*.

---

## GPU metrics from DCGM (the silicon side)

| Metric | Good | Alert |
|---|---|---|
| `DCGM_FI_PROF_SM_ACTIVE` | high under load | persistently low while queue>0 = bad batching |
| `DCGM_FI_DEV_FB_USED` | weights + KV | near total = OOM risk |
| `DCGM_FI_DEV_GPU_TEMP` | <85°C | >90°C = throttle |
| `DCGM_FI_DEV_POWER_USAGE` | near TDP under load | - |
| `DCGM_FI_DEV_XID_ERRORS` | 0 | **any XID = hardware/driver fault** (doc 11) |

**Senior DevOps tip:** alert on `DCGM_FI_DEV_XID_ERRORS` early and loudly. XID errors are the
GPU telling you it had a fault (ECC, fallen-off-the-bus, NVLink error). They precede most "pod
mysteriously died" incidents and a bad GPU will silently tank a whole TP group. Cordon the node
on repeated XIDs.

---

## Wiring it to Prometheus + Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

**ServiceMonitor for vLLM:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: vllm, namespace: monitoring, labels: { release: monitoring } }
spec:
  namespaceSelector: { matchNames: ["llm"] }
  selector: { matchLabels: { app: vllm-llama3-8b } }
  endpoints: [{ port: http, path: /metrics, interval: 15s }]
```
**ServiceMonitor for DCGM** is shipped/wired by the GPU Operator; confirm it's scraped:
```bash
kubectl get servicemonitor -A | grep -E 'dcgm|vllm'
```

**Senior Dev tip:** import the official **vLLM Grafana dashboard** (shipped in the vLLM repo
under `examples/`) and the **NVIDIA DCGM dashboard** (Grafana.com ID **12239**) rather than
building from scratch. Then add one panel that overlays `num_requests_waiting` against
`gpu_cache_usage_perc` - that single correlation explains 80% of latency incidents.

---

## Scaling vLLM

### Horizontal replicas (model fits per replica)
```bash
kubectl scale deployment vllm-llama3-8b --replicas=3 -n llm
```
Each replica loads the **full model** and needs its own GPU(s). A Service round-robins - but plain
round-robin is *prefix-cache-blind*; for smart routing see **doc 09**.

### Autoscaling on queue depth - KEDA (the current, clean way)
HPA can't read vLLM metrics directly without the Prometheus Adapter; **KEDA** does it natively:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: vllm-scaler, namespace: llm }
spec:
  scaleTargetRef: { name: vllm-llama3-8b }
  minReplicaCount: 1
  maxReplicaCount: 6
  cooldownPeriod: 300                      # don't thrash expensive GPUs
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://monitoring-kube-prometheus-prometheus.monitoring:9090
        query: |
          sum(vllm:num_requests_waiting{app="vllm-llama3-8b"})
          / count(vllm:num_requests_running{app="vllm-llama3-8b"})
        threshold: "5"                     # avg queue > 5 per replica -> scale up
```

**Senior DevOps tip:** set a generous `cooldownPeriod` (and KEDA scale-down stabilization).
GPU pods take minutes to come up (doc 04) and cost real money - flapping between 3 and 6 replicas
every two minutes is the worst of both worlds. Be quick to add replicas and slow to remove them. Capacity math
and scale-to-zero are in **doc 10**.

**Architect tip:** horizontal replicas only help *throughput*, never single-request *latency*.
If TTFT is your problem at low load, more replicas do nothing - you need a faster model, FP8,
speculative decoding, or disaggregated prefill (doc 09). Diagnose which axis you're scaling before
you add GPUs.

---

## Graceful shutdown - don't drop in-flight requests

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 120     # > your p99 request duration
      containers:
        - name: vllm
          lifecycle:
            preStop:
              exec: { command: ["/bin/sh","-c","sleep 15"] }   # let LB stop routing first
```
vLLM handles SIGTERM by draining in-flight work. The `preStop` sleep covers the race where the
pod is `Terminating` but endpoints haven't propagated yet.

**Senior DevOps tip:** size `terminationGracePeriodSeconds` above your *p99 generation time*,
not an average. A request generating 2000 tokens can run 30-60s; a 30s grace period will SIGKILL
it. Pair this with a `PodDisruptionBudget` (doc 11) so voluntary disruptions (node drains,
upgrades) can't take all replicas at once.

---

## Namespace guardrails

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: gpu-quota, namespace: llm }
spec:
  hard:
    requests.nvidia.com/gpu: "8"
    limits.nvidia.com/gpu: "8"
    requests.memory: "400Gi"
```

**Architect tip:** GPU `ResourceQuota` is your blast-radius control and your chargeback unit.
One quota per tenant namespace means a runaway team can't starve another of GPUs, and your finance
report is `sum(quota)` per namespace. Combine with priority classes so production preempts batch
(doc 11).

---

## Triage playbook

### OOMKilled (exit 137)
```bash
kubectl describe pod <pod> -n llm | grep -A4 'Last State'
```
-> Model bigger than VRAM, KV cache too greedy, or too many concurrent seqs. Lower
`--gpu-memory-utilization` to 0.85, cap `--max-num-seqs`, or add GPUs/quantize.

### High TTFT
- `num_requests_waiting` high -> under-provisioned -> scale (doc 10) or route smarter (doc 09).
- `SM_ACTIVE` low while waiting -> batches starved -> raise `--max-num-batched-tokens`.
- Long prompts dominate -> chunked prefill (on in V1) + prefix caching + KV-aware routing.

### Preemptions climbing
`vllm:num_preemptions_total` rising = KV cache thrash. Reduce `--max-num-seqs`, lower
`--max-model-len` if context is over-provisioned, or add capacity. Not an error - a capacity signal.

### Pod stuck Pending
```bash
kubectl describe pod <pod> -n llm | tail -20    # "Insufficient nvidia.com/gpu"
```
-> No free GPU, taint not tolerated, or wrong SKU affinity (doc 01).

---

## Command reference

```bash
kubectl get pods -n llm -w
kubectl logs -f deploy/vllm-llama3-8b -n llm
kubectl exec -it deploy/vllm-llama3-8b -n llm -- nvidia-smi
kubectl top pods -n llm
kubectl get events -n llm --sort-by=.lastTimestamp | tail -20
```

---

## Day-2 production checklist

- [ ] `startupProbe` + tight readiness/liveness (doc 03)
- [ ] Models pre-staged (doc 04); cold-start measured, not assumed
- [ ] vLLM + DCGM scraped by Prometheus; official dashboards imported
- [ ] Alerts on: `num_requests_waiting`, preemptions, `gpu_cache_usage_perc`, XID errors, TTFT p99
- [ ] KEDA scaling on queue depth with sane cooldown (doc 10)
- [ ] `terminationGracePeriodSeconds` > p99 generation time + `preStop`
- [ ] `PodDisruptionBudget` set (doc 11)
- [ ] `ResourceQuota` + priority classes per namespace
- [ ] Runbook links in every alert

-> Next: [06 - Distributed Inference](06-distributed-inference.md) - when one node isn't enough.
