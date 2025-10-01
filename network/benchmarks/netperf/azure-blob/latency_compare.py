#!/usr/bin/env python3
"""Extract median and p95 latencies from fio JSON results and plot overlays.

Produces:
- fio-results/latency-comparison.csv
- fio-results/latency-read-overlay.png
- fio-results/latency-write-overlay.png

Latencies are output in milliseconds (ms).
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Dict, List, Tuple

import matplotlib.pyplot as plt

plt.switch_backend("Agg")


def gather_latencies(results_dir: Path) -> Tuple[List[str], List[str], Dict[str, Dict[str, Dict[str, float]]]]:
    """Return (clusters, ordered_block_sizes, metrics)
    metrics[mode][cluster][bs] = {"p50_ms":..., "p95_ms":...}
    """
    from plot_fio_comparison import gather_metrics

    cluster_names, block_sizes, metrics_full = gather_metrics(results_dir)
    metrics: Dict[str, Dict[str, Dict[str, float]]] = {"read": {}, "write": {}}
    for mode in ("read", "write"):
        for cluster in cluster_names:
            metrics[mode][cluster] = {}
            for bs in block_sizes:
                # fetch the job metrics; if missing, default zeros
                j = metrics_full.get(mode, {}).get(cluster, {}).get(bs, {})
                # Prefer percentile map under clat_ns.percentile for p50/p95; fallback to latency_percentile fields
                p50 = 0.0
                p95 = 0.0
                # If clat_ns.percentile exists, keys are strings like "50.000000"
                clat = j.get("clat_ns") or {}
                if isinstance(clat, dict) and clat.get("percentile"):
                    pct = clat["percentile"]
                    try:
                        # keys are floats formatted as strings
                        p50 = float(pct.get("50.000000") or pct.get("50") or 0) / 1_000_000.0
                        p95 = float(pct.get("95.000000") or pct.get("95") or 0) / 1_000_000.0
                    except Exception:
                        p50 = 0.0
                        p95 = 0.0
                else:
                    # fallback to lat_ns.mean (p50 unknown) -> treat mean as p50
                    lat_mean_ns = j.get("latency_ms") or j.get("latency_ns")
                    if isinstance(lat_mean_ns, dict):
                        # prefer latency_ms.mean if available
                        m = lat_mean_ns.get("mean") or 0
                        if 'ms' in str(lat_mean_ns):
                            p50 = float(m)
                            p95 = float(m)
                        else:
                            # assume ns
                            p50 = float(m) / 1_000_000.0
                            p95 = float(m) / 1_000_000.0
                    else:
                        # last fallback: metrics_full "latency_ms" key
                        p50 = float(j.get("latency_ms", 0))
                        p95 = float(j.get("latency_ms", 0))

                metrics[mode][cluster][bs] = {"p50_ms": p50, "p95_ms": p95}
    return cluster_names, block_sizes, metrics


def write_csv(out: Path, clusters: List[str], block_sizes: List[str], metrics: Dict[str, Dict[str, Dict[str, float]]]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        header = ["mode", "percentile", "block_size"] + clusters
        writer.writerow(header)
        for mode in ("read", "write"):
            for pct in ("p50_ms", "p95_ms"):
                for bs in block_sizes:
                    row = [mode, pct, bs] + [metrics[mode][c].get(bs, {}).get(pct, 0.0) for c in clusters]
                    writer.writerow(row)
    print(f"Wrote {out}")


def plot_overlay(out: Path, clusters: List[str], block_sizes: List[str], metrics: Dict[str, Dict[str, Dict[str, float]]], mode: str, pct_key: str) -> None:
    fig, ax = plt.subplots(figsize=(10, 5))
    x = list(range(len(block_sizes)))
    for c in clusters:
        vals = [metrics[mode][c].get(bs, {}).get(pct_key, 0.0) for bs in block_sizes]
        ax.plot(x, vals, marker="o", label=c)

    ax.set_xticks(x)
    ax.set_xticklabels(block_sizes, rotation=45)
    ax.set_xlabel("block size")
    ax.set_ylabel("Latency (ms)")
    ax.set_title(f"{mode.capitalize()} latency ({pct_key})")
    ax.grid(True, which="both", linestyle="--", linewidth=0.5)
    ax.legend()
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"Wrote {out}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--results-dir", type=Path, default=Path("fio-results"))
    p.add_argument("--output-dir", type=Path, default=Path("fio-results"))
    return p


def main() -> None:
    args = build_parser().parse_args()
    clusters, block_sizes, metrics = gather_latencies(args.results_dir)
    csv_out = args.output_dir / "latency-comparison.csv"
    write_csv(csv_out, clusters, block_sizes, metrics)

    plot_overlay(args.output_dir / "latency-read-p50.png", clusters, block_sizes, metrics, "read", "p50_ms")
    plot_overlay(args.output_dir / "latency-read-p95.png", clusters, block_sizes, metrics, "read", "p95_ms")
    plot_overlay(args.output_dir / "latency-write-p50.png", clusters, block_sizes, metrics, "write", "p50_ms")
    plot_overlay(args.output_dir / "latency-write-p95.png", clusters, block_sizes, metrics, "write", "p95_ms")


if __name__ == "__main__":
    main()
