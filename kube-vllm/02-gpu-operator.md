# 02 - NVIDIA GPU Operator

> **Scope:** the one Helm release that turns bare GPU nodes into schedulable, observable,
> partitionable Kubernetes capacity - and the production decisions hidden in its defaults.

## What problem it solves

Doing GPU node setup by hand means installing and version-matching, on **every** node:
driver -> CUDA -> `nvidia-container-toolkit` -> device plugin -> DCGM -> MIG manager -> feature discovery.
Do it manually across a fleet and you will get drift, and drift in this stack means silent NCCL hangs.

The **GPU Operator** runs all of it as Kubernetes-native DaemonSets, reconciled from a single CRD.

```
GPU Operator (controller-manager Deployment)
        │ reconciles
        ▼
ClusterPolicy  <- one config object for the whole fleet
        │ manages
        ├── nvidia-driver-daemonset          install/load driver (or skip if pre-installed)
        ├── nvidia-container-toolkit          wire CDI into containerd/CRI-O
        ├── nvidia-device-plugin-daemonset    advertise nvidia.com/gpu to kubelet
        ├── nvidia-dcgm-exporter              Prometheus GPU metrics
        ├── nvidia-mig-manager                apply MIG profiles
        ├── gpu-feature-discovery (GFD)       auto-label nodes with GPU facts
        └── node-feature-discovery (NFD)      auto-label nodes with kernel/PCI facts
```

**Architect tip:** the Operator is the right call for cloud and homogeneous fleets. On bare
metal with a hardened, security-team-approved kernel/driver image, run the Operator with
`driver.enabled=false` and let it manage *everything except* the driver. Fighting the Operator
over driver installation on locked-down hosts is a losing battle - split the responsibility.

---

## Install

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install --wait gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --version v24.9.2 \                              # pin the Operator version
  --set driver.version="550.127.08" \              # pin the driver branch
  --set toolkit.enabled=true \
  --set dcgmExporter.enabled=true \
  --set mig.strategy=mixed                         # allow mixed MIG profiles per node
```

```bash
# Verify - every DaemonSet should be fully Ready on GPU nodes
kubectl get pods -n gpu-operator -o wide
kubectl get ds   -n gpu-operator
# A node passes validation when this label appears:
kubectl get nodes -l nvidia.com/gpu.deploy.driver=true
```

**Senior DevOps tip:** add `--wait` and watch the `nvidia-operator-validator` pod - it runs
a CUDA workload and only then flips the node to "GPU ready". If you deploy vLLM before the
validator passes, the pod schedules onto a not-yet-ready node and CrashLoops. Gate your app
rollout (Argo CD sync wave, or an init-container probe) on the validator, not just node `Ready`.

---

## ClusterPolicy - the single config object

Created automatically by Helm; inspect and patch rather than recreate.

```bash
kubectl get clusterpolicy
kubectl describe clusterpolicy cluster-policy
```

A production-leaning example - pre-installed driver, MIG enabled, DCGM with custom metrics:

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: cluster-policy
spec:
  driver:
    enabled: false                 # bare metal: driver baked into node image
  toolkit:
    enabled: true                  # still let Operator wire CDI/containerd
  devicePlugin:
    enabled: true
    config:
      name: device-plugin-config   # ConfigMap for time-slicing/MPS (see below)
  mig:
    strategy: mixed
  migManager:
    enabled: true
  dcgmExporter:
    enabled: true
    config:
      name: dcgm-custom-metrics     # ConfigMap to add LLM-relevant fields
  gfd:
    enabled: true
  nodeStatusExporter:
    enabled: true
```

---

## GPU Feature Discovery - the labels everything else depends on

GFD + NFD auto-label nodes. These labels power every `nodeAffinity` and `nodeSelector` in the series:

```bash
kubectl get node gpu-node-1 --show-labels | tr ',' '\n' | grep -E 'nvidia|feature'

# nvidia.com/gpu.present=true
# nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
# nvidia.com/gpu.memory=81559
# nvidia.com/gpu.count=8
# nvidia.com/gpu.compute.major=9            <- Hopper = sm_90 (FP8 capable)
# nvidia.com/cuda.driver.major=550
# nvidia.com/mig.capable=true
# feature.node.kubernetes.io/pci-10de.present=true   <- NFD: NVIDIA PCI vendor present
```

**Senior Dev tip:** `nvidia.com/gpu.compute.major` is your FP8 gate. Hopper (9) and
Blackwell support native FP8; Ampere (8) does not. Pin FP8-quantized models to `>= 9` with
affinity or vLLM will fall back/refuse and you'll waste a deploy cycle. See doc 03/04.

---

## Configuring GPU sharing (time-slicing / MPS)

Sharing is declared in a ConfigMap referenced by `devicePlugin.config`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-plugin-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4          # advertise each GPU 4×
  # MPS alternative (better isolation than time-slicing):
  mps-profile: |-
    version: v1
    sharing:
      mps:
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```
Then label nodes to select the profile per pool:
```bash
kubectl label node dev-gpu-1 nvidia.com/device-plugin.config=mps-profile
```

**Senior DevOps tip:** roll sharing config changes node-pool by node-pool, not fleet-wide.
The device plugin restarts when its config changes, briefly dropping `nvidia.com/gpu` from the
node - in-flight pods are fine, but the scheduler will see capacity flap. Cordon -> apply -> uncordon
on a canary pool first.

---

## DCGM Exporter - the GPU half of observability

DCGM (Data Center GPU Manager) exports the metrics that tell you whether your GPUs are
*actually working* vs idle-but-allocated.

```bash
kubectl port-forward -n gpu-operator svc/nvidia-dcgm-exporter 9400:9400
curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
```

| Metric | Meaning | Watch for |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | SM utilization % | <50% during load = poor batching |
| `DCGM_FI_PROF_SM_ACTIVE` | Fraction of SMs active (more honest than UTIL) | The real "am I using the GPU" signal |
| `DCGM_FI_DEV_FB_USED/FREE` | Framebuffer memory | FB_FREE near 0 = KV-cache OOM risk |
| `DCGM_FI_DEV_POWER_USAGE` | Watts | Pinned at TDP = compute-bound (good) |
| `DCGM_FI_DEV_GPU_TEMP` | °C | >85°C -> thermal throttle, latency creeps up |
| `DCGM_FI_PROF_PCIE_TX/RX_BYTES` | PCIe traffic | High during TP = topology problem |
| `DCGM_FI_PROF_NVLINK_TX/RX_BYTES` | NVLink traffic | Where TP traffic *should* be |

**Senior Dev tip:** `DCGM_FI_DEV_GPU_UTIL` lies - it reads 100% if *any* kernel is running,
even a tiny one. Use `DCGM_FI_PROF_SM_ACTIVE` and `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` (Tensor Core
occupancy) to know if you're truly saturating the silicon. A vLLM server can show 100% UTIL while
the Tensor Cores sit at 15% because batches are too small.

**Senior DevOps tip:** raise DCGM's scrape cost concern early - the full profiling fieldset
adds GPU overhead. Use a custom metrics ConfigMap to export only what your dashboards/alerts use.

---

## MIG management at fleet scale

```bash
# See available profiles on a node
kubectl exec -it -n gpu-operator <driver-pod> -- nvidia-smi mig -lgip

# Apply a named MIG layout via label (Operator's mig-manager reconciles it)
kubectl label node gpu-node-1 nvidia.com/mig.config=all-1g.10gb --overwrite
```
Reconfiguring MIG **drains and resets the GPU** - the mig-manager cordons the node, evicts GPU
pods, repartitions, then uncordons. Plan it like a node maintenance, not a config tweak.

**Architect tip:** MIG is the right multi-tenant isolation primitive, but it fragments
capacity - seven `1g.10gb` slices can't be reassembled for one 70B model without a disruptive
reconfigure. Don't MIG your *whole* fleet. Keep a pool of whole-GPU/NVLink nodes for big models
and a MIG pool for many-small-model tenants. Capacity that can't change shape is capacity you'll
strand.

---

## Driver strategy decision

| Mode | Set | When |
|---|---|---|
| Operator-managed driver | `driver.enabled=true` + pinned `driver.version` | Cloud VMs, fast-moving, homogeneous |
| Pre-installed driver | `driver.enabled=false` | Bare metal, security-hardened images, exotic kernels |
| Precompiled/signed modules | `driver.usePrecompiled=true` | Secure Boot / immutable OS where DKMS is blocked |

---

## Troubleshooting

```bash
kubectl logs -n gpu-operator deployment/gpu-operator
kubectl describe pod -n gpu-operator <driver-pod>          # driver build issues
kubectl logs -n gpu-operator -l app=nvidia-operator-validator
kubectl exec -it <any-gpu-pod> -- nvidia-smi               # ground truth
```

| Problem | Likely cause | Fix |
|---|---|---|
| Driver pod stuck `Init`/`Error` | Kernel headers missing / Secure Boot | Use `usePrecompiled`, or pre-install driver |
| Device plugin never Ready | Driver pod not yet Running (ordering) | Wait; check driver first |
| `nvidia.com/gpu` not in capacity | Plugin not on that node / validation failed | Check validator pod logs |
| DCGM metrics missing | Exporter crashed or scrape blocked | Logs + ServiceMonitor namespace selector |
| MIG label ignored | `mig.strategy` mismatch / GPU not MIG-capable | Confirm `nvidia.com/mig.capable=true` |
| All GPU pods evicted suddenly | mig-manager reconfiguring | Expected on MIG label change - schedule it |

-> Next: [03 - Deploying vLLM](03-vllm-deployment.md) - now that nodes serve GPUs, run an engine on them.
