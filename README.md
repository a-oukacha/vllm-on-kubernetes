# vLLM on Kubernetes - Production LLM Serving

A deep, current (2026) walkthrough series for running large language models in production on
Kubernetes with vLLM and Ray: GPU plumbing, single-node vLLM, multi-node distributed serving with
Ray / LeaderWorkerSet, then gateway routing, autoscaling, reliability, security, benchmarking, and a
full GitOps reference architecture.

[![CI](https://github.com/Open-The-Gates/vllm-on-kubernetes/actions/workflows/ci.yml/badge.svg)](https://github.com/Open-The-Gates/vllm-on-kubernetes/actions/workflows/ci.yml)

> Written for engineers who already know Kubernetes and want the production decisions, not a
> hello-world. I wrote it to pin down the choices that actually matter when you put an LLM endpoint
> behind an SLO: GPU sharing, KV cache, rollout safety, cost, and multi-tenancy.

## Who it is for

This assumes you are comfortable with Kubernetes already. It is the production layer on top: what to
pick and why, where it breaks, and what it costs. Every chapter carries three tiers of field notes:

| Tier | Audience | Focus |
|------|----------|-------|
| Senior Dev tip | Application / model engineers | engine flags, model behavior, request shaping, KV cache |
| Senior DevOps tip | Platform / SRE | scheduling, rollout, failure modes, observability, cost |
| Architect tip | Staff / principal | trade-offs, topology, capacity, org boundaries, build-vs-buy |

## Reading order

The chapters build on each other; read them in order.

Part A - foundations (single node):

1. [GPU + Kubernetes fundamentals](kube-vllm/01-gpu-k8s-fundamentals.md) - device plugin, CDI, MIG/MPS/time-slicing/DRA, taints, topology
2. [GPU Operator](kube-vllm/02-gpu-operator.md) - ClusterPolicy, DCGM, GFD/NFD, driver strategy
3. [Deploying vLLM](kube-vllm/03-vllm-deployment.md) - `vllm serve`, the V1 engine, modern flags, probes, sizing
4. [Storage & models](kube-vllm/04-storage-and-models.md) - PVC strategies, fast model loading, OCI modelcars
5. [Operations & monitoring](kube-vllm/05-operations-monitoring.md) - vLLM V1 metrics, DCGM, Prometheus/Grafana, KEDA basics

Part B - distributed & production:

6. [Distributed inference](kube-vllm/06-distributed-inference.md) - tensor/pipeline parallelism, when to go multi-GPU
7. [RayService production serving](kube-vllm/07-rayservice-production-serving.md)
8. [LeaderWorkerSet multi-node](kube-vllm/08-leaderworkerset-multinode.md)
9. [LLM gateway & routing](kube-vllm/09-llm-gateway-routing.md)
10. [Autoscaling, capacity & cost](kube-vllm/10-autoscaling-capacity-cost.md)
11. [Reliability & rollouts](kube-vllm/11-reliability-rollouts.md)
12. [Security & multi-tenancy](kube-vllm/12-security-multitenancy.md)
13. [Benchmarking & observability](kube-vllm/13-benchmarking-observability.md)
14. [Reference architecture & GitOps](kube-vllm/14-reference-architecture-gitops.md)

## Scope

This is a written series, not a runnable lab kit - the YAML in each chapter is illustrative and
production-shaped, meant to be read and adapted, not applied blind. It assumes you bring your own GPU
cluster. Where a choice is cloud- or hardware-specific, the trade-off is called out rather than
hidden behind one vendor.

```bash
git clone https://github.com/Open-The-Gates/vllm-on-kubernetes.git
cd vllm-on-kubernetes
# read it as a site:
make serve        # docsify on localhost:3009
```

## Status / TODO

- [ ] vLLM moves fast; flags and the V1 engine notes are current as of early 2026 and will need a
      refresh as releases land.
- [ ] The RayService and LeaderWorkerSet chapters could use a worked failure-injection example.
- [ ] Add a short "minimum viable single-GPU" appendix for people without a multi-node cluster.

## License

MIT - see [LICENSE](LICENSE).
