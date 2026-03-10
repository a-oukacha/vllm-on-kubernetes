# 12 - Security & Multi-Tenancy

> **Scope:** locking down an LLM serving platform - network isolation, authN/Z, secrets, tenant
> isolation, supply chain for *weights* (not just images), and the LLM-specific threats (prompt
> injection, data exfiltration, model theft). LLM endpoints are a new, high-value attack surface;
> the GPU behind them is expensive enough to be worth stealing compute from.

## The threat model (what's actually different about LLMs)

| Threat | LLM-specific angle |
|---|---|
| **Unauthorized access** | An open LLM endpoint = free GPU compute for an attacker (crypto-style abuse) |
| **Data exfiltration** | Prompts/responses carry PII, secrets, proprietary context (RAG documents) |
| **Prompt injection** | Untrusted input steers the model / tools - your domain (agentic + tools) |
| **Cross-tenant leakage** | Shared prefix/KV cache or shared replica leaking one tenant's data to another |
| **Model theft** | Weights are valuable IP; a mounted PVC or pullable image is exfiltration surface |
| **Resource abuse** | One tenant exhausting GPUs / KV cache -> DoS for others |

**Architect tip: an LLM endpoint is simultaneously a compute resource** (expensive, abusable),
a **data conduit (everything flowing through is sensitive), and a decision-maker** (in your
anti-fraud/due-diligence platforms its output drives actions). Each demands different controls: rate
limiting + auth for the compute, encryption + isolation for the data, and guardrails + audit for the
decisions. Don't secure it like a stateless API - it's all three at once.

---

## Layer 1 - Network: default-deny, then allow

Start with deny-all in the namespace, then open only what's needed:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: llm }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# vLLM accepts traffic ONLY from the gateway; egress only to model store + DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: vllm-allow, namespace: llm }
spec:
  podSelector: { matchLabels: { app: vllm-llama3-8b } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: gateway } } }]
      ports: [{ port: 8000 }]
  egress:
    - to: [{ namespaceSelector: {} , podSelector: { matchLabels: { k8s-app: kube-dns } } }]   # DNS
      ports: [{ port: 53, protocol: UDP }]
    - to: [{ ipBlock: { cidr: 10.0.0.0/8 } }]    # internal model store / Redis only
```

**Senior DevOps tip:** the egress rule is the one people forget and the one that matters most for
data exfiltration. A vLLM pod with open egress can be made (via a compromised dependency or a
malicious model) to phone home with whatever's in its context. **Lock egress to exactly the model
store, DNS, and metrics** - no general internet. Set `HF_HUB_OFFLINE=1` (doc 03) so the engine never
even tries to reach Hugging Face at runtime; everything it needs is already on the PVC. Default-deny
egress is your strongest single anti-exfil control.

**Senior DevOps tip:** multi-node groups (LWS/RayService) need intra-group traffic (Ray/NCCL
ports) explicitly allowed under default-deny, or you get the "workers never join" hang (docs 06-08).
Allow it *within the group's label*, not cluster-wide.

---

## Layer 2 - Identity: authN/Z at the gateway, mTLS in the mesh

Enforce identity **once, at the gateway** (doc 09) - never per-replica:
- **API keys / JWT / OIDC** for client identity (who is calling).
- **Per-tenant authorization** - tenant A's key can only reach tenant A's models.
- **mTLS between gateway <-> vLLM** (service mesh) so a compromised pod can't impersonate the gateway
 and hit the engine directly, bypassing auth/rate-limits.

```yaml
# Istio: require mTLS to vLLM, and only the gateway's identity may call it
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: vllm-mtls, namespace: llm }
spec:
  mtls: { mode: STRICT }
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: vllm-authz, namespace: llm }
spec:
  selector: { matchLabels: { app: vllm-llama3-8b } }
  action: ALLOW
  rules:
    - from: [{ source: { principals: ["cluster.local/ns/gateway/sa/llm-gateway"] } }]
```

**Architect tip:** this is straight **zero-trust** applied to inference - the network is hostile,
identity is enforced every hop, and the engine trusts *only* the gateway's SA, not "anything in the
namespace". The gateway becomes your single policy decision point (PDP): authN, authZ, rate limits,
and audit all live there. A vLLM pod reachable directly, bypassing the gateway, is a hole that
voids every policy above it. mTLS STRICT + AuthorizationPolicy closes it.

---

## Layer 3 - Rate limiting & quotas (DoS + cost control)

Token-aware limits at the gateway protect GPUs from one tenant starving the rest:
```yaml
# conceptual - Envoy/Istio rate limit keyed on tenant + token budget
ratelimit:
  - key: tenant-id
    requests_per_unit: 600
    unit: minute
  - key: tenant-id
    descriptor: tokens
    tokens_per_unit: 1_000_000        # token-budget limiting, not just request count
    unit: hour
```

**Senior Dev tip:** rate-limit on **tokens**, not just requests. One request asking for
`max_tokens: 32000` costs ~1000× one asking for 32 - request-count limits let a single expensive call
saturate a replica's KV cache and preempt everyone (doc 05). Also enforce a server-side `max_tokens`
ceiling so a tenant can't request unbounded generation. Token-budget limiting is the LLM-correct
fairness primitive.

---

## Layer 4 - Tenant isolation (how hard a boundary?)

| Model | Isolation | Cost | When |
|---|---|---|---|
| **Shared replica, logical** (gateway auth + per-tenant rate limit) | soft | cheapest | trusted internal tenants |
| **Namespace per tenant** (own Deployments, quota, NetworkPolicy) | medium | medium | separate teams |
| **Node pool per tenant** (taints/affinity) | hard | high | untrusted / regulated tenants |
| **Cluster per tenant** | hardest | highest | strict compliance / data residency |

**Architect tip:** the dangerous middle is **shared replica with shared caches**. Prefix caching
and KV-aware routing (doc 09) are throughput wins, but a shared prefix cache across tenants is a
*side channel* - timing differences can reveal whether another tenant already submitted a given
prompt, and careless KV reuse could leak content. For a multi-tenant FinTech/regulated platform,
**partition the cache by tenant** (per-tenant pools, or cache keyed with a tenant salt) or don't
share replicas across trust boundaries at all. Decide the isolation tier from the tenants' trust
level and your compliance obligations - then the cache-sharing question answers itself.

---

## Layer 5 - Secrets & the weight supply chain

**Secrets:** HF tokens, API keys, Redis passwords -> external secret store (Vault / cloud SM via
External Secrets Operator), never plain `Secret` manifests in git.
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: hf-token, namespace: llm }
spec:
  secretStoreRef: { name: vault, kind: ClusterSecretStore }
  target: { name: hf-token }
  data: [{ secretKey: token, remoteRef: { key: llm/hf, property: token } }]
```

**Supply chain for weights** - extend image controls to models (doc 04's modelcar pattern makes this
natural): sign the model image with Cosign, and admission-gate that only signed weights run.
```yaml
# Kyverno: only signed model/engine images admitted
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: verify-llm-images }
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-signature
      match: { any: [{ resources: { kinds: [Pod], namespaces: [llm] } }] }
      verifyImages:
        - imageReferences: ["registry.internal/models/*", "vllm/*"]
          attestors: [{ entries: [{ keys: { publicKeys: "<cosign-pub-key>" } }] }]
```

**Architect tip:** "which exact weights produced this decision?" must be answerable for any
LLM in a regulated decision path (anti-fraud, KYC/AML). Mutable model paths on a filer can't answer
it. Immutable, signed model artifacts (digests) + admission enforcement turn weight provenance
into the same auditable supply chain you already have for code - the model version becomes an
immutable digest in the decision's audit record. This is governance, not just security.

---

## Layer 6 - LLM-application threats (the new class)

Beyond infra, the *model* is an attack surface:
- **Prompt injection** - untrusted content (a document, a tool result, a web page) carries
 instructions the model obeys. Acute in agentic/tool systems.
- **Insecure tool/output handling** - model output drives tools/queries -> injection becomes RCE/SSRF.
- **Sensitive data in context** - RAG pulls confidential docs into prompts that may be logged/cached.

Mitigations live above vLLM (your app/agent layer) but the platform enables them:
- **Sandbox tool execution** (microVM / Firecracker, gVisor) - your wheelhouse; never run
 model-driven tool calls in a privileged context.
- **Output validation / guardrails** before acting on model output.
- **PII redaction & scoped retrieval** so the model only sees what the caller is entitled to.
- **Don't log raw prompts/responses** to systems without the same data classification as the source.

**Architect tip:** the serving platform's job is to make the *insecure thing hard and the secure
thing easy* - provide a sandboxed tool-execution sidecar pattern, a guardrail/validation step in the
gateway path, and a "context never leaves its classification" data contract. Prompt-injection defense
is ultimately an application-layer problem, but a platform that ships sandboxing and redaction as
paved-road defaults prevents every team from getting it wrong independently. Treat model output as
**untrusted user input** everywhere downstream - that one mental model closes most of the class.

---

## Security checklist

- [ ] Default-deny NetworkPolicy; egress locked to store/DNS/metrics only; `HF_HUB_OFFLINE=1`
- [ ] Intra-group (Ray/NCCL) traffic explicitly allowed for multi-node
- [ ] AuthN/Z + rate limiting enforced at the gateway, not per-replica
- [ ] mTLS STRICT gateway<->vLLM; engine trusts only the gateway SA
- [ ] Token-budget rate limits + server-side `max_tokens` ceiling
- [ ] Tenant isolation tier matched to trust/compliance; caches partitioned across trust boundaries
- [ ] Secrets from Vault/External Secrets, never in git
- [ ] Signed model + engine images; admission-enforced; weight provenance auditable
- [ ] Tool execution sandboxed (microVM/gVisor); model output treated as untrusted
- [ ] Non-root, read-only rootfs, dropped capabilities on engine pods (Pod Security Standards: restricted)

-> Next: [13 - Benchmarking & Observability](13-benchmarking-observability.md).
