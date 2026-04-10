# 08 - LeaderWorkerSet: Native Multi-Node Serving

> This doc shards one model across N nodes with **LeaderWorkerSet (LWS)**, a Kubernetes-SIG API
> built for multi-host inference. For the common case - "serve this big model across several nodes" -
> it's the leaner, more K8s-native alternative to RayService (doc 07).

## The problem LWS solves

A Deployment scales *independent, identical* pods. A model sharded with TP+PP is the opposite shape:
one logical replica made of many cooperating pods (a leader that serves the API + workers that hold
model shards). Those pods must be created together, scheduled together, and **restarted together** if
any one dies. Neither Deployments nor StatefulSets can express that. LWS adds exactly that primitive:
a **group** (leader + workers) is the unit of replication.

```
LeaderWorkerSet (replicas: 2)
├── Group 0  ─ leader (serves :8080) ─ worker ─ worker ...   <- one model replica
└── Group 1  ─ leader (serves :8080) ─ worker ─ worker ...   <- another model replica
        every pod in a group = one node's GPUs; group size = nodes per replica
```

**Architect tip:** LWS is the right default for multi-node *serving* in 2026. It's a thin,
purpose-built CRD with no Ray control plane to operate, it gang-schedules cleanly, it's topology-aware
(below), and it's what the inference gateway ecosystem (doc 09) targets. Reach back to RayService
(07) only when you need Ray Serve's application features. To just make a 405B model answer requests,
LWS is far less to run.

---

## The canonical multi-node vLLM LWS

This serves Llama-3.1-405B across **2 nodes × 8 GPUs** (TP 8 within a node, PP 2 across nodes).
vLLM's bundled `multi-node-serving.sh` bootstraps a Ray cluster *inside the group* (LWS provides the
membership env vars); the leader then runs `vllm serve`.

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: vllm-405b
  namespace: llm
spec:
  replicas: 2                              # 2 independent model replicas (for HA + throughput)
  leaderWorkerTemplate:
    size: 2                                # 2 pods per group -> pipeline_parallel_size = 2
    restartPolicy: RecreateGroupOnPodRestart   # any pod dies -> recreate the WHOLE group
    # ---------- LEADER (runs Ray head + the vLLM API server) ----------
    leaderTemplate:
      metadata:
        labels: { role: leader, app: vllm-405b }
      spec:
        tolerations:
          - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
        containers:
          - name: vllm-leader
            image: vllm/vllm-openai:v0.9.2
            command: ["sh","-c"]
            args:
              - |
                bash /vllm-workspace/examples/online_serving/multi-node-serving.sh \
                    leader --ray_cluster_size=$(LWS_GROUP_SIZE);
                vllm serve /models/Meta-Llama-3.1-405B-Instruct-FP8 \
                    --served-model-name llama-405b \
                    --tensor-parallel-size 8 \
                    --pipeline-parallel-size 2 \
                    --kv-cache-dtype fp8 \
                    --max-model-len 16384 \
                    --port 8080
            env:
              - { name: HUGGING_FACE_HUB_TOKEN, valueFrom: { secretKeyRef: { name: hf-token, key: token } } }
            ports: [{ containerPort: 8080 }]
            resources:
              limits: { nvidia.com/gpu: "8", memory: 1100Gi }
              requests: { cpu: "100", memory: 900Gi }
            readinessProbe:
              tcpSocket: { port: 8080 }
              initialDelaySeconds: 30
              periodSeconds: 10
              failureThreshold: 60          # long leash for 405B load (acts like a startupProbe)
            volumeMounts:
              - { name: model, mountPath: /models, readOnly: true }
              - { name: dshm, mountPath: /dev/shm }
        volumes:
          - { name: model, persistentVolumeClaim: { claimName: model-pvc } }
          - { name: dshm, emptyDir: { medium: Memory, sizeLimit: 32Gi } }
    # ---------- WORKERS (join the leader's Ray cluster, hold shards) ----------
    workerTemplate:
      metadata:
        labels: { app: vllm-405b }
      spec:
        tolerations:
          - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
        containers:
          - name: vllm-worker
            image: vllm/vllm-openai:v0.9.2
            command: ["sh","-c"]
            args:
              - |
                bash /vllm-workspace/examples/online_serving/multi-node-serving.sh \
                    worker --ray_address=$(LWS_LEADER_ADDRESS)
            env:
              - { name: HUGGING_FACE_HUB_TOKEN, valueFrom: { secretKeyRef: { name: hf-token, key: token } } }
            resources:
              limits: { nvidia.com/gpu: "8", memory: 1100Gi }
              requests: { cpu: "100", memory: 900Gi }
            volumeMounts:
              - { name: model, mountPath: /models, readOnly: true }
              - { name: dshm, mountPath: /dev/shm }
        volumes:
          - { name: model, persistentVolumeClaim: { claimName: model-pvc } }
          - { name: dshm, emptyDir: { medium: Memory, sizeLimit: 32Gi } }
---
# Service targets only the leaders - that's where the OpenAI API lives
apiVersion: v1
kind: Service
metadata: { name: vllm-405b, namespace: llm }
spec:
  selector:
    leaderworkerset.sigs.k8s.io/name: vllm-405b
    role: leader
  ports: [{ name: http, port: 80, targetPort: 8080 }]
  type: ClusterIP
```

**Senior Dev tip:** the magic is the two LWS-injected env vars: `LWS_GROUP_SIZE` (how many
pods in this group -> the Ray cluster size the leader waits for) and `LWS_LEADER_ADDRESS` (the
DNS the workers dial to join). You never hardcode pod IPs. `size: 2` here means 2 *pods per group*,
which becomes `pipeline-parallel-size 2`; `tensor-parallel-size 8` is the per-node GPU count.
Total GPUs per replica = size × GPUs-per-pod = 2 × 8 = 16.

**Senior DevOps tip:** `RecreateGroupOnPodRestart` is the whole point - and a sharp edge. If one
worker pod dies, LWS tears down and recreates the *entire group*, because a half-a-model is useless.
That's correct, but it means a single flaky GPU/node restarts a 16-GPU replica. This is why you run
`replicas: 2` (so the other replica serves during the recreate) and why GPU health alerting (XID
errors, doc 05) matters - you want to *evict the bad node*, not endlessly recreate the group onto it.

---

## Gang scheduling - all-or-nothing placement

A 16-GPU replica must get **all 16 GPUs at once** or none - otherwise pods sit half-scheduled,
holding GPUs hostage while waiting for peers that never come (a classic deadlock when two big jobs
each grab half the cluster). LWS integrates with gang-scheduling via **Kueue** (or Volcano/Coscheduling):

```yaml
metadata:
  labels:
    kueue.x-k8s.io/queue-name: gpu-queue        # Kueue admits the whole group atomically
```

**Architect tip:** once you run *more than one* multi-node model on a shared cluster, gang
scheduling stops being optional. Without it, two 16-GPU deployments racing for a 24-GPU cluster can
each grab 12 and both hang forever - a deadlock no amount of "just add retries" fixes. Standardize on
Kueue (or Volcano) as the admission layer for all multi-node GPU work from day one; retrofitting it
after a deadlock incident is painful.

---

## Topology-aware placement - keep a group on one fast island

PP across nodes tolerates RDMA, but you still want a group's pods physically close (same rack/block)
to minimize inter-node latency. With Kueue's Topology-Aware Scheduling:

```yaml
leaderTemplate:
  metadata:
    annotations:
      kueue.x-k8s.io/podset-required-topology: "cloud.provider.com/topology-block"
      kueue.x-k8s.io/podset-group-name: "vllm-405b-group"
workerTemplate:
  metadata:
    annotations:
      kueue.x-k8s.io/podset-required-topology: "cloud.provider.com/topology-block"
      kueue.x-k8s.io/podset-group-name: "vllm-405b-group"
```

**Senior DevOps tip:** `required` topology fails the pod if the constraint can't be met;
`preferred` degrades gracefully. On a busy cluster `required-topology` can leave a group `Pending`
because no single block has enough free GPUs even though the cluster total does. Start with
`preferred` unless your interconnect *demands* co-location (large dense TP across nodes), and watch
for the trade-off between packing efficiency and placement quality.

---

## SubGroups - for disaggregated prefill/decode in one LWS

LWS can split a group into **subgroups** with their own topology - exactly the shape needed for
disaggregated serving (prefill pods vs decode pods, doc 09):

```yaml
metadata:
  annotations:
    leaderworkerset.sigs.k8s.io/subgroup-exclusive-topology: rack
spec:
  leaderWorkerTemplate:
    size: 4
    subGroupPolicy:
      subGroupSize: 2          # e.g. 2 prefill pods + 2 decode pods, each subgroup co-located
```

**Architect tip:** subgroups are how you express "prefill cluster + decode cluster as one
managed unit" without juggling two LeaderWorkerSets and a fragile coordinator. If you're heading
toward disaggregated P/D (doc 09), design with subgroups now - it keeps the whole P/D replica as one
schedulable, upgradable object.

---

## Rolling updates

```yaml
spec:
  rolloutStrategy:
    type: RollingUpdate
    rollingUpdateConfiguration:
      maxUnavailable: 1        # update one group at a time
      maxSurge: 1              # optionally bring up a new group before tearing one down
```

**Senior DevOps tip:** with multi-node groups, `maxSurge: 1` momentarily needs a *whole extra
replica's GPUs* (16 here) - same surge-capacity concern as RayService upgrades (doc 07). If you
can't spare the surge, use `maxSurge: 0, maxUnavailable: 1`, accept reduced capacity during the
roll, and make sure your remaining replica + autoscaling can carry the traffic. Never run `replicas:
1` for a model you can't drop - there's no safe way to update it.

---

## RayService (07) vs LeaderWorkerSet (08) - pick one

| Need | Pick |
|---|---|
| Just serve a big model across nodes, lean ops | **LWS** |
| Topology-aware / gang scheduling via Kueue | **LWS** |
| Disaggregated P/D as one unit (subgroups) | **LWS** |
| Inference-gateway-native (doc 09) | **LWS** (common pairing) |
| Serve autoscaling on ongoing-requests | **RayService** |
| Multi-model composition / request graphs | **RayService** |
| Already a Ray shop (training+serving on Ray) | **RayService** |
| Fault-tolerant control plane (GCS+Redis) | **RayService** |

---

## Common LWS issues

| Symptom | Cause | Fix |
|---|---|---|
| Group `Pending` forever | Gang scheduling missing / topology too strict | Add Kueue; relax `required`->`preferred` |
| Two big deploys deadlock | No gang scheduler | Kueue/Volcano admission |
| Group recreated repeatedly | Flaky GPU/node keeps killing a worker | Cordon node on XID errors (doc 05/11) |
| Workers never join leader | `LWS_LEADER_ADDRESS` unreachable / Ray ports blocked | NetworkPolicy allow; check DNS |
| API only on some pods | Service selecting workers too | Select `role: leader` only |
| Update needs 2× GPUs | `maxSurge: 1` on multi-node group | Use `maxSurge: 0` or budget surge |

-> Next: [09 - LLM Gateway & Routing](09-llm-gateway-routing.md) - put smart, KV-aware traffic in front.
