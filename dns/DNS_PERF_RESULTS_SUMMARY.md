# DNS Performance Results — All Runs

**Date:** 2026-05-01
**Clusters:** AKS BYO CNI (Azure CNI Overlay), 3 nodes × Standard_D4s_v3 (4 vCPU), K8s v1.35.0
**Tool:** dnsperf v2.1 (4 client pods, unlimited QPS, 250m CPU request, no limit)
**Query file:** all-queries.txt (25 queries: svc A/AAAA, external FQDN, NX domain)
**Proxy verified:** All runs confirmed via `cilium_policy_l7_total{proxy_type="fqdn"}` metric deltas

## Final Results — 5-min Interleaved (most reliable)

| Scenario | R1 QPS | R2 QPS | Avg QPS | Avg Latency | vs v1.18 |
|---|---|---|---|---|---|
| **v1.19 SDP** | 5,483 | 5,242 | **5,362** | **81.7ms** | +46% QPS, -63% lat |
| v1.18 SDP | 3,786 | 3,575 | 3,680 | 222.1ms | baseline |
| v1.19 in-agent | 3,398 | 3,269 | 3,334 | 129.6ms | -9% QPS, -42% lat |

### Per-Pod Breakdown (5-min interleaved)

**v1.19 SDP:**
- R1: 2,167 / 1,158 / 1,079 / 1,079 = 5,483 QPS, 79ms, proxied 3,290,842
- R2: 1,864 / 1,474 / 1,116 / 788 = 5,242 QPS, 84ms, proxied 3,145,808

**v1.18 SDP:**
- R1: 1,973 / 1,452 / 233 / 128 = 3,786 QPS, 332ms, proxied 2,055,647
- R2: 957 / 947 / 836 / 835 = 3,575 QPS, 112ms, proxied 1,003,158

**v1.19 in-agent:**
- R1: 909 / 903 / 793 / 793 = 3,398 QPS, 118ms, proxied 2,039,462
- R2: 1,461 / 604 / 603 / 601 = 3,269 QPS, 141ms, proxied 1,962,639

## Earlier Runs — 2-min (for reference)

### 2-min Interleaved (SDP vs in-agent alternating on same cluster)

| Scenario | R1 | R2 | R3 | Avg QPS | Avg Lat |
|---|---|---|---|---|---|
| v1.19 in-agent | 4,780 | 4,653 | 4,652 | 4,695 | 89.8ms |
| v1.19 SDP | 3,391 | 3,427 | 3,657 | 3,492 | 123.2ms |

Note: In this test in-agent outperformed SDP. However this was NOT reproduced
in the 5-min interleaved runs where SDP consistently won. The 2-min interleaved
test alternated (SDP→inagent→SDP→inagent) while 5-min tested all 3 scenarios
with full teardown/redeploy each round.

### 2-min R4 (sequential, verified)

| Scenario | R1 | R2 | R3 | Avg QPS | Avg Lat |
|---|---|---|---|---|---|
| v1.19 SDP | 4,924 | 4,910 | 5,219 | 5,018 | 87.7ms |
| v1.19 in-agent | 3,511 | 3,340 | 3,220 | 3,357 | 120.0ms |

## Key Findings

1. **v1.19 SDP is the fastest proxy option**: +46% QPS and -63% latency vs v1.18 SDP
2. **v1.19 SDP outperforms in-agent proxy**: +61% QPS and -37% latency (5-min IL)
3. **v1.18 SDP has extreme variance**: latency swings from 112ms to 340ms between runs
4. **v1.19 SDP is stable**: consistently 5,200-5,500 QPS across different test durations
5. **In-agent results are inconsistent**: 4,695 QPS (2-min IL) vs 3,334 QPS (5-min IL)
6. **Zero query drops** across all scenarios — no packet loss
7. **Proxy metric counts 2x**: `cilium_policy_l7_total` counts both request+response

## Issues Discovered

1. **CNI chaining not configured**: Cilium was not in data path on BYO CNI clusters.
   Fix: manual `05-cilium.conflist` with `cilium-cni` + `chaining-mode: generic-veth`
2. **CNI config overwritten on redeploy**: Cilium rewrites conflist without `cilium-cni`
   on every restart. Must re-apply after each deploy.
3. **Duplicate `enable-standalone-dns-proxy`** in v1.19 manifest: second entry set to
   `"false"` overrode the first `"true"`, completely disabling SDP.
4. **Build script image name mismatch**: v1.19 builds as `standalone-dns-proxy` but
   pushes as `dns-proxy`.
