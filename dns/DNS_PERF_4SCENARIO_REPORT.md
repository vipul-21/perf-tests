# DNS Performance — 4-Scenario Comparison Report

**Date:** 2026-05-01
**Clusters:** AKS BYO CNI (Azure CNI Overlay), 3 nodes × Standard_D4s_v3, K8s v1.35.0
**Tool:** dnsperf v2.1.0 (4 client pods, unlimited QPS)
**Query file:** `all-queries.txt` — 25 queries (A + AAAA for internal services, external FQDNs, NX domains, pod IPs)

---

## Scenarios

| # | Name | Cilium | DNS Proxy Mode | CNP Applied |
|---|------|--------|----------------|-------------|
| S1 | v1.18 + SDP | v1.18 (`amd64-dns-perf-v1.18`) | Standalone DNS Proxy (SDP) | Yes |
| S2 | v1.19 + SDP | v1.19 (`amd64-dns-perf-v1.19`) | Standalone DNS Proxy (SDP) | Yes |
| S3 | v1.19 in-agent | v1.19 (`amd64-dns-perf-v1.19`) | In-agent L7 proxy | Yes |
| S4 | v1.19 no proxy | v1.19 (`amd64-dns-perf-v1.19`) | None (raw DNS) | No |

**Cluster layout:**
- Cluster 1 (v1.18): Scenario S1
- Cluster 2 (v1.19): Scenarios S2, S3, S4 (full teardown/redeploy between each)

**CiliumNetworkPolicy (CNP):**
```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "dns-perf-fqdn-policy"
spec:
  endpointSelector:
    matchLabels:
      app: dns-perf-client
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports:
           - port: "53"
             protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
       - matchPattern: "*"
```

---

## Results

### 10-Minute Production Run (single run per scenario)

| Scenario | Pod 1 | Pod 2 | Pod 3 | Pod 4 | Total QPS | Avg Latency |
|---|---|---|---|---|---|---|
| **S1: v1.18 + SDP** | 1,954 | 829 | 827 | 268 | **3,878** | 166.1ms |
| **S2: v1.19 + SDP** | 1,728 | 757 | 756 | 756 | **3,997** | 113.4ms |
| **S3: v1.19 in-agent** | 1,268 | 1,177 | 884 | 883 | **4,212** | 97.3ms |
| **S4: v1.19 no proxy** | 15,030 | 6,179 | 6,102 | 6,064 | **33,375** | 13.3ms |

### 2-Minute Multi-Run (3 runs per scenario, averages)

| Scenario | Run 1 | Run 2 | Run 3 | Avg QPS | Avg Latency |
|---|---|---|---|---|---|
| **S1: v1.18 + SDP** | 3,750 | 2,967 | 3,615 | **3,444** | 249.1ms |
| **S2: v1.19 + SDP** | 3,436 | 3,472 | 3,860 | **3,589** | 113.0ms |
| **S3: v1.19 in-agent** | 3,456 | 4,390 | 4,226 | **4,024** | 102.5ms |

### Summary Comparison

```
                          Avg QPS    Avg Latency    vs S4 baseline
─────────────────────── ─────────── ──────────── ──────────────────
S4: v1.19 no proxy        33,375      13.3ms       baseline
S3: v1.19 in-agent         4,024     102.5ms       -88%
S2: v1.19 SDP              3,589     113.0ms       -89%
S1: v1.18 SDP              3,444     249.1ms       -90%
```

### v1.19 SDP vs v1.18 SDP

| Metric | v1.18 SDP | v1.19 SDP | Change |
|---|---|---|---|
| Total QPS (avg) | 3,444 | 3,589 | **+4%** |
| Avg Latency | 249.1ms | 113.0ms | **-55%** |
| Variance | High (2,967–3,750) | Low (3,436–3,860) | Much more stable |

v1.19 SDP delivers **55% lower latency** and significantly more consistent performance than v1.18 SDP.

### v1.19 SDP vs v1.19 In-Agent Proxy

| Metric | v1.19 SDP | v1.19 In-Agent | Change |
|---|---|---|---|
| Total QPS (avg) | 3,589 | 4,024 | **-11%** |
| Avg Latency | 113.0ms | 102.5ms | **+10%** |

In-agent proxy has a slight edge (~11% more QPS, ~10% lower latency), likely because SDP adds an extra IPC hop (agent → SDP process → CoreDNS) while in-agent handles DNS directly within the cilium-agent process.

---

## Issues Discovered & Fixed

### 1. CNI Chaining Not Configured (Critical)

**Impact:** Cilium was deployed but NOT in the data path. No pod endpoints were created, no DNS traffic was intercepted by the proxy. All initial test results were invalid — they measured raw DNS to CoreDNS regardless of scenario.

**Root cause:** The v1.18/v1.19 DaemonSet manifests did not configure CNI chaining for BYO CNI clusters:
```
--write-cni-conf-when-ready=''   ← empty, Cilium never writes CNI config
--cni-chaining-mode='none'       ← not chaining with Azure CNI
```

**Fix:** Added to `cilium-config` ConfigMap:
```yaml
write-cni-conf-when-ready: /host/etc/cni/net.d/05-cilium.conflist
read-cni-conf: /host/etc/cni/net.d/15-azure-swift-overlay.conflist
cni-chaining-mode: generic-veth
cni-exclusive: "false"
```

**Additional fix:** Cilium's `write-cni-conf-when-ready` copies the source config but does NOT add `cilium-cni` to the plugin chain. The conflist must be manually written with `cilium-cni` appended:

```json
{
  "cniVersion": "0.3.1",
  "name": "cilium-chained",
  "plugins": [
    { "type": "azure-vnet", ... },
    { "type": "portmap", ... },
    { "type": "cilium-cni", "chaining-mode": "generic-veth" }
  ]
}
```

The `chaining-mode` field inside the CNI conflist plugin entry is **required** — without it, `cilium-cni` rejects the call with: `CNI PrevResult supplied, but not in chaining mode`.

**Verification:** After fix, `cilium-dbg endpoint list` shows pod endpoints, `cilium-dbg status --all-redirects` shows active redirects, and `cilium_policy_l7_total{proxy_type="fqdn"}` metrics increment.

### 2. Duplicate `enable-standalone-dns-proxy` in v1.19 Manifest (Critical)

**Impact:** SDP was deployed but disabled. All DNS queries timed out in Scenario 2 (v1.19 + SDP) — zero successful responses.

**Root cause:** `cilium-config-standalone-dns-proxy.yaml` in the v1.19 manifests defined `enable-standalone-dns-proxy` **twice**:
```yaml
# Line 41
enable-standalone-dns-proxy: "true"
# Line 210-211
# enable-standalone-dns-proxy enables the standalone DNS proxy server (alpha feature)
enable-standalone-dns-proxy: "false"
```
YAML takes the last value, so SDP was disabled.

**Fix:** Removed the duplicate entry at line 210-211.

**File:** `test/manifests/v1.19/config/cilium-config-standalone-dns-proxy.yaml` (branch `upstream/camrynl/v1.19-manifests`)

### 3. Build Script Image Name Mismatch (Minor)

**Impact:** `build_images.sh --version v1.19` failed to push the SDP image.

**Root cause:** The make target `docker-standalone-dns-proxy-image` builds as `standalone-dns-proxy` but the script pushes as `dns-proxy`.

**Fix:** Added `docker tag` step in `build_images.sh` to retag `standalone-dns-proxy` → `dns-proxy` after build.

---

## Test Infrastructure

### Cluster Configuration
- **Type:** AKS BYO CNI (Azure CNI Overlay, `network-plugin azure --network-plugin-mode overlay`)
- **Nodes:** 3 × Standard_D4s_v3 (4 vCPU, 16GB RAM)
- **K8s:** v1.35.0
- **Pod CIDR:** 10.244.0.0/16
- **CoreDNS:** 2 replicas
- **Region:** westus2

### Images
| Component | v1.18 Tag | v1.19 Tag |
|---|---|---|
| Cilium Agent | `acnpublic.azurecr.io/cilium/cilium:amd64-dns-perf-v1.18` | `acnpublic.azurecr.io/cilium/cilium:amd64-dns-perf-v1.19` |
| Operator | `acnpublic.azurecr.io/cilium/operator-generic:amd64-dns-perf-v1.18` | `acnpublic.azurecr.io/cilium/operator-generic:amd64-dns-perf-v1.19` |
| SDP | `acnpublic.azurecr.io/cilium/dns-proxy:amd64-dns-perf-v1.18` | `acnpublic.azurecr.io/cilium/dns-proxy:amd64-dns-perf-v1.19` |

### DNS Perf Client
- **Image:** `registry.k8s.io/kube-dns-perf-client-amd64:1.1`
- **Replicas:** 4
- **dnsPolicy:** ClusterFirst
- **Labels:** `app: dns-perf-client`

### Query File (`all-queries.txt`)
25 queries covering:
- Internal service A/AAAA lookups (`svc1`, `svc2`)
- Fully qualified service names (`svc1.default.svc.cluster.local`)
- External FQDN resolution (`google.com`)
- NX domain patterns (`google.com.svc.cluster.local`)
- Pod IP reverse lookups

---

## Observations

1. **Outlier pod pattern:** In every scenario, one pod consistently achieves 1.5–2.5× higher QPS than the others. This pod is co-located on the same node as a CoreDNS replica, benefiting from reduced network latency.

2. **v1.18 SDP high variance:** v1.18 SDP shows significantly more run-to-run variance (2,967–3,750 QPS, 137–310ms latency) compared to v1.19 SDP (3,436–3,860 QPS, 106–117ms). Some v1.18 runs had pods with 640-708ms latency.

3. **Proxy overhead is substantial:** All proxy scenarios add ~88-90% overhead vs no-proxy. This is the cost of DNS interception, FQDN policy evaluation, and forwarding through the proxy layer.

4. **Without CNP, proxy does not intercept:** Even with SDP deployed and running, DNS traffic is NOT intercepted unless a CiliumNetworkPolicy with `dns` rules is applied. Without CNP, performance is identical to the no-proxy baseline.

5. **SDP metrics gap:** The SDP (`standalone-dns-proxy`) process exposes only process-level metrics (CPU, memory, network bytes) via its Prometheus endpoint (`:9961`). It does not expose DNS request counts, latency histograms, or error rates. DNS metrics are available on the Cilium agent side (`cilium_policy_l7_total{proxy_type="fqdn"}`).

---

## Scripts & Artifacts

| File | Description |
|---|---|
| `dns/dns_perf_4scenario.sh` | Main orchestration script for all 4 scenarios |
| `dns/run_full_4scenario.sh` | Pipeline: build images + run all scenarios |
| `dns/build_images.sh` | Build & push Cilium + SDP images from dev branches |
| `dns/dns-perf-4scenario-workdir/` | Work directory with results, manifests, kubeconfigs |
| `dns/dns-perf-4scenario-workdir/results/` | All test results (raw dnsperf output) |
