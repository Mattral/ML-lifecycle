# ML Lifecycle Explorer — System Design

A top-tier reference architecture for a globally-distributed, secure, and observable
educational ML platform. Designed for **high availability, low latency, and zero-trust**.

---

## 1. Goals & Non-Goals

| Dimension      | Target                                                      |
| -------------- | ----------------------------------------------------------- |
| Availability   | 99.95% (≤ 4h 22m downtime/year)                             |
| Latency (p95)  | < 150 ms TTFB globally (edge-cached SPA)                    |
| Throughput     | 10k concurrent learners, burst to 50k                       |
| RPO / RTO      | RPO ≤ 5 min · RTO ≤ 15 min                                  |
| Security       | Zero-trust, signed images, SBOM-attested, OWASP ASVS L2     |
| Cost           | Horizontal scaling on demand, scale-to-near-zero off-peak   |

**Non-goals:** real model training in browser (simulated); no PII storage today.

---

## 2. High-Level Architecture

```text
                              ┌───────────────────┐
                  HTTPS       │   Cloudflare /    │  WAF, DDoS, bot mgmt,
   Users ───────────────────▶ │   CDN + Edge      │  TLS 1.3, HTTP/3
                              └─────────┬─────────┘
                                        │ cache-miss
                              ┌─────────▼─────────┐
                              │  Ingress (NGINX)  │  cert-manager + Let's Encrypt
                              │  rate-limit, mTLS │
                              └─────────┬─────────┘
                                        │
                       ┌────────────────┼────────────────┐
                       │                │                │
                ┌──────▼─────┐   ┌──────▼─────┐   ┌──────▼─────┐
                │ ml-explorer│   │ ml-explorer│   │ ml-explorer│   HPA 2→10
                │   (nginx)  │   │   (nginx)  │   │   (nginx)  │   readOnlyFS
                └──────┬─────┘   └──────┬─────┘   └──────┬─────┘   non-root
                       │                │                │
                       └────────────────┼────────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │  Redis (StatefulSet)│  cache · sessions ·
                              │  AOF + LRU 256MB    │  rate-limit counters
                              └─────────┬─────────┘
                                        │
                              ┌─────────▼─────────┐
                              │  Observability    │  Prometheus · Loki ·
                              │  + Tracing (OTel) │  Tempo · Grafana
                              └───────────────────┘
```

---

## 3. Component Responsibilities

### Edge (CDN)
- Caches hashed Vite bundles forever (`Cache-Control: public, immutable`).
- Terminates TLS, enforces HSTS, blocks OWASP top 10 via WAF rules.

### Ingress (NGINX)
- Single entry point inside the cluster, with cert-manager for automated TLS.
- Per-IP rate limit (10 rps burst 20), connection limits, request-size caps.

### Application Pods (`ml-explorer`)
- Stateless React SPA served by hardened NGINX (UID 101, read-only rootfs,
  all caps dropped, `no-new-privileges`).
- Liveness / readiness / startup probes for fast, safe rollouts.
- HPA scales on CPU (70%) and memory (80%); PDB keeps ≥ 1 pod during disruptions.

### Redis (StatefulSet)
- AOF persistence, `allkeys-lru` eviction at 256 MB.
- Use cases: response cache, session affinity, rate-limit counters,
  feature-store lookup demo, Pub/Sub for pipeline run events.
- Headless service for stable DNS; PVC for durability.

### Observability
- **Metrics:** Prometheus scrapes `/metrics` (RED + USE); SLO dashboards in Grafana.
- **Logs:** Loki via Promtail, structured JSON, 30-day retention.
- **Traces:** OpenTelemetry SDK → Tempo, sampled 10%.
- **Alerting:** Alertmanager → PagerDuty for SLO burn-rate.

---

## 4. CI/CD — Supply-Chain Hardened

```text
PR ──▶ Lint · Types · Tests · Build ──▶ Trivy + CodeQL
                                          │
                                          ▼
main ──▶ Multi-arch Docker (amd64/arm64) ──▶ Cosign keyless sign
                                          ──▶ SBOM (Syft, SPDX)
                                          ──▶ Trivy image scan → SARIF
                                          ──▶ kubeconform on k8s/*
                                          ──▶ Deploy: staging (auto)
tag v*.*.*  ───────────────────────────────▶ Deploy: production (gated env)
```

Key controls: Sigstore keyless signing, in-toto provenance, SBOM artifact,
GitHub Environments with required reviewers for prod, branch protection
with required checks + signed commits.

---

## 5. Security Posture

| Layer            | Control                                                  |
| ---------------- | -------------------------------------------------------- |
| Network          | NetworkPolicy default-deny, ingress 80 only, egress DNS  |
| Pod              | non-root (101), readOnlyRootFilesystem, drop ALL caps    |
| Image            | Distroless-style nginx-alpine, Trivy CRITICAL/HIGH gate  |
| Supply chain     | Cosign signature + SBOM + provenance attestation         |
| HTTP             | CSP, HSTS, X-Frame-Options, Referrer-Policy, Permissions |
| Secrets          | External Secrets Operator → AWS/GCP Secret Manager       |
| AuthN/Z (future) | OIDC via Lovable Cloud, RLS, role table separation       |

---

## 6. Failure Modes & Mitigations

| Failure                  | Mitigation                                              |
| ------------------------ | ------------------------------------------------------- |
| Pod crash                | Liveness probe + RollingUpdate (maxUnavailable=0)       |
| Node loss                | 3+ replicas, anti-affinity, PDB minAvailable=1          |
| Region outage            | Multi-region CDN + active/standby cluster, DNS failover |
| Redis OOM                | LRU eviction + alerts at 80% memory                     |
| Bad release              | Blue/green via two Services + instant traffic switch    |
| Secret leak              | Short-lived tokens, automated rotation, audit logs      |
| Dependency CVE           | Dependabot + Trivy + weekly scheduled scan              |

---

## 7. Scalability Strategy

1. **Vertical first** for Redis (single writer), **horizontal** for stateless tier.
2. HPA on CPU + custom metrics (requests/sec via Prometheus Adapter).
3. Cluster Autoscaler / Karpenter for node-level elasticity.
4. CDN absorbs 95%+ of static traffic; origin handles only cache-miss + dynamic.
5. Future: shard Redis with Cluster mode when working set > 4 GB.

---

## 8. Roadmap

- [ ] Multi-region active/active with Route 53 latency routing
- [ ] Service mesh (Linkerd) for mTLS + golden metrics
- [ ] Argo CD for GitOps-driven progressive delivery
- [ ] Flagger canary analysis backed by Prometheus SLOs
- [ ] OpenFeature flags for safe experimentation
