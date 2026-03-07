# 11 - Reliability & Rollouts

> **Scope:** keeping the service up through node failures, GPU faults, upgrades, and model swaps - 
> PodDisruptionBudgets, GPU failure handling, multi-AZ, and **canary/blue-green model rollouts**.
> LLM serving has failure modes web services don't (a single bad GPU silently corrupts a whole TP
> group), and rollouts you can't do naïvely (you can't "rolling update" a model whose outputs changed).

## The reliability model: what can fail

| Failure | Blast radius | Defense |
|---|---|---|
| Pod OOM / crash | one replica | restart + PDB + multiple replicas |
| GPU fault (XID/ECC) | whole TP group on that node | XID alerting -> cordon/drain node |
| Node loss | all replicas/groups on it | anti-affinity, multi-AZ, fast reschedule |
| AZ outage | everything in that AZ | spread across AZs |
| Bad model rollout | every request, instantly | canary/blue-green, not rolling |
| Bad config/flag | every replica | progressive rollout + fast rollback (GitOps, doc 14) |

**Architect tip:** for your domain (anti-fraud scoring, due-diligence QA) the worst failure isn't
*downtime* - it's **silent wrongness**: a degraded GPU producing subtly corrupted logits, or a model
rollout that quietly changes answers. Downtime pages you; silent wrongness ships bad decisions to
production. Invest in *correctness* signals (output canaries, eval gates on rollout, XID alerting),
not just uptime probes. A 99.99%-available endpoint serving corrupted outputs is worse than a clear outage.

---

## PodDisruptionBudgets - survive voluntary disruptions

Node drains (upgrades, autoscaler consolidation) are *voluntary* disruptions. Without a PDB, a drain
can evict all your replicas at once.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: vllm-llama3-pdb, namespace: llm }
spec:
  minAvailable: 1                 # never let voluntary disruption drop below 1 serving replica
  selector: { matchLabels: { app: vllm-llama3-8b } }
```

**Senior DevOps tip:** a PDB only constrains **voluntary** disruptions (drains, evictions) - it
does *nothing* for a hard node crash. And a too-strict PDB (`minAvailable` = replica count) **blocks
node drains entirely**, so cluster upgrades and autoscaler consolidation hang forever. Set
`minAvailable` to *replicas − 1* (or a percentage) so you keep capacity *and* let maintenance
proceed. For a single-replica model, a PDB can't help - run at least two.

---

## GPU failure handling - the LLM-specific one

A failing GPU is the nastiest LLM failure: it may not crash, just emit **XID errors** and produce
garbage or hang NCCL - taking down an entire TP group. You must detect and *evict the node*, not
restart the pod onto the same bad hardware.

```yaml
# PrometheusRule: page on XID errors, then automate cordon
groups:
  - name: gpu-health
    rules:
      - alert: GPUXidError
        expr: increase(DCGM_FI_DEV_XID_ERRORS[5m]) > 0
        labels: { severity: critical }
        annotations: { summary: "XID error on {{ $labels.Hostname }} GPU {{ $labels.gpu }}" }
      - alert: GPUThrottling
        expr: DCGM_FI_DEV_GPU_TEMP > 90
        labels: { severity: warning }
```

The GPU Operator can auto-act via node health checks / GPU fault remediation (drain + reboot/RMA
flow). At minimum, alert -> cordon:
```bash
kubectl cordon <bad-node>
kubectl drain <bad-node> --ignore-daemonsets --delete-emptydir-data
```

**Senior DevOps tip:** wire XID errors to **automatic cordon**, not just a page. A bad GPU that
keeps accepting pods will keep killing TP groups (doc 08's "group recreated repeatedly") and your
LWS will dutifully reschedule the replica right back onto the poison node. Break the loop: a node
with repeated XIDs gets cordoned automatically; humans handle the RMA. Manual remediation is too slow
for a card actively corrupting a fleet.

---

## Spreading risk - anti-affinity & multi-AZ

Don't let one node/AZ failure take all replicas:
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector: { matchLabels: { app: vllm-llama3-8b } }
          topologyKey: kubernetes.io/hostname        # spread replicas across nodes
      - weight: 50
        podAffinityTerm:
          labelSelector: { matchLabels: { app: vllm-llama3-8b } }
          topologyKey: topology.kubernetes.io/zone   # and across AZs
```

**Architect tip: multi-AZ for GPUs has a tax web apps don't pay - cross-AZ bandwidth costs
and latency**, and GPU capacity is often AZ-constrained (the H100s you want may only exist in one
zone). For *single-node* replicas, spread across AZs for HA. For *multi-node* TP/PP groups, keep each
group **within one AZ** (you need the low-latency interconnect - doc 06) and spread *different groups*
across AZs. HA across AZs at the replica level; locality within AZ at the group level.

---

## Model rollouts - you cannot "rolling update" a model

Swapping `llama3-v1` -> `llama3-v2` isn't a code deploy. Outputs change. A rolling update mixes both
versions across live traffic with no control and no clean rollback. Use **canary** or **blue-green**,
driven at the gateway (doc 09).

### Canary (gradual traffic shift)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: llm-canary, namespace: llm }
spec:
  parentRefs: [{ name: llm-gateway }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /v1 } }]
      backendRefs:
        - { name: vllm-v1-pool, group: inference.networking.k8s.io, kind: InferencePool, weight: 90 }
        - { name: vllm-v2-pool, group: inference.networking.k8s.io, kind: InferencePool, weight: 10 }
```
Shift 10 -> 50 -> 100 as eval/quality metrics hold. Roll back = set weight back to 0. Instant.

### Blue-green (atomic switch)
Both versions fully deployed; flip 100% of traffic at once after validating green out-of-band.
Fastest rollback (flip back), highest cost (2× GPUs during overlap).

**Architect tip:** gate model rollouts on an offline eval + online quality canary, not just
"pods are healthy". A new model can be perfectly *available* and measurably *worse* (higher
hallucination, regressed on your benchmark). Your rollout pipeline should run the model against a
golden eval set (your +10% RAG-precision benchmark is exactly this kind of gate) and watch online
proxies (refusal rate, output length distribution, user thumbs-down) at each canary step. "Healthy"
is necessary, not sufficient. This is the single biggest difference between deploying a service and
deploying a model.

**Senior DevOps tip:** keep N−1 - the previous model version stays deployed (or one flag flip
away) for the rollback window. Re-pulling and re-loading a 140GB model during an incident is the
slowest possible rollback (doc 04). Blue-green or a held canary pool makes rollback a weight change
(seconds) instead of a redeploy (many minutes). Cost of the idle old version << cost of a slow
rollback during a quality incident.

---

## Graceful drain (recap, because rollouts depend on it)

From doc 05: `terminationGracePeriodSeconds` > p99 generation time + a `preStop` sleep so the LB stops
routing before SIGTERM. During canary/blue-green, draining replicas must finish their in-flight
streams or users see truncated responses mid-rollout.

---

## Health checks that detect *wrong*, not just *down*

Standard `/health` catches "process dead". Add a **synthetic correctness probe** - a CronJob that
sends a known prompt and checks the response is sane (right shape, non-empty, deterministic-ish for
greedy decoding):
```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: vllm-canary-check, namespace: llm }
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: probe
              image: curlimages/curl
              command: ["/bin/sh","-c"]
              args:
                - |
                  R=$(curl -s vllm-llama3-8b.llm/v1/chat/completions -H 'Content-Type: application/json' \
                       -d '{"model":"llama3-8b","messages":[{"role":"user","content":"2+2="}],"max_tokens":5,"temperature":0}')
                  echo "$R" | grep -q '4' || { echo "SANITY FAIL: $R"; exit 1; }
```

**Senior Dev tip:** a synthetic correctness probe catches the failure mode probes miss - the
engine is *up and serving*, but a bad GPU, a botched quantization, or a corrupted weight load makes
it produce garbage. For greedy decoding (`temperature: 0`) outputs are near-deterministic, so a
known prompt -> known answer check is a cheap, powerful liveness signal for *correctness*. Page on it.

---

## Reliability checklist

- [ ] ≥2 replicas per production model (PDB can't help a singleton)
- [ ] PDB with `minAvailable = replicas − 1` (allows drains)
- [ ] XID error alert -> **automatic** node cordon
- [ ] Pod anti-affinity across nodes; groups within-AZ, replicas across-AZ
- [ ] Canary or blue-green at the gateway - never rolling-update a model
- [ ] Rollout gated on offline eval + online quality canary
- [ ] Previous version one weight-flip from restored
- [ ] `terminationGracePeriodSeconds` > p99 + `preStop`
- [ ] Synthetic correctness probe (catches silent wrongness)
- [ ] Multi-node groups NOT on spot (doc 10)

-> Next: [12 - Security & Multi-Tenancy](12-security-multitenancy.md).
