#!/usr/bin/env python3
"""Produce a CSV and overlay plots comparing read/write throughput across cluster result dirs."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict, List, Tuple

import matplotlib.pyplot as plt

plt.switch_backend("Agg")


def gather(results_dir: Path) -> Tuple[List[str], List[str], Dict[str, Dict[str, Dict[str, float]]]]:
    """Return (cluster_names, ordered_block_sizes, metrics) where metrics[mode][cluster][bs] = throughput_mib_s"""
    from plot_fio_comparison import gather_metrics

    clusters, block_sizes, all_metrics = gather_metrics(results_dir)
    # all_metrics is mode->cluster->bs->{throughput_mib_s,...}
    # Convert to simpler structure
    metrics: Dict[str, Dict[str, Dict[str, float]]] = {"read": {}, "write": {}}
    for mode in ("read", "write"):
        for cluster in clusters:
            metrics[mode][cluster] = {}
            for bs in block_sizes:
                metrics[mode][cluster][bs] = all_metrics[mode].get(cluster, {}).get(bs, {}).get("throughput_mib_s", 0.0)
    return clusters, block_sizes, metrics


def write_csv(out: Path, clusters: List[str], block_sizes: List[str], metrics: Dict[str, Dict[str, Dict[str, float]]]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        header = ["mode", "block_size"] + clusters
        writer.writerow(header)
        for mode in ("read", "write"):
            for bs in block_sizes:
                row = [mode, bs] + [metrics[mode][c].get(bs, 0.0) for c in clusters]
                writer.writerow(row)
    print(f"Wrote {out}")


def plot_overlay(out: Path, clusters: List[str], block_sizes: List[str], metrics: Dict[str, Dict[str, Dict[str, float]]], mode: str) -> None:
    fig, ax = plt.subplots(figsize=(10, 5))
    sizes = [s for s in block_sizes]
    x = range(len(sizes))

    for cluster in clusters:
        vals = [metrics[mode][cluster].get(bs, 0.0) for bs in sizes]
        ax.plot(x, vals, marker="o", label=cluster)

    ax.set_xticks(x)
    ax.set_xticklabels(sizes, rotation=45)
    ax.set_xlabel("block size")
    ax.set_ylabel("Throughput (MiB/s)")
    ax.set_title(f"{mode.capitalize()} throughput comparison")
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
    clusters, block_sizes, metrics = gather(args.results_dir)
    csv_out = args.output_dir / "throughput-comparison.csv"
    write_csv(csv_out, clusters, block_sizes, metrics)
    plot_overlay(args.output_dir / "throughput-read-overlay.png", clusters, block_sizes, metrics, "read")
    plot_overlay(args.output_dir / "throughput-write-overlay.png", clusters, block_sizes, metrics, "write")


if __name__ == "__main__":
    main()
