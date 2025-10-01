#!/usr/bin/env python3
"""Render comparative fio plots across multiple cluster result directories."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import matplotlib.pyplot as plt

plt.switch_backend("Agg")

MetricValues = Dict[str, float]


def _parse_block_size(bs: str) -> int:
    suffix_multipliers = {
        "k": 1024,
        "m": 1024 ** 2,
        "g": 1024 ** 3,
        "t": 1024 ** 4,
    }
    normalized = bs.strip().lower()
    if normalized[-1].isdigit():
        return int(normalized)
    multiplier = suffix_multipliers.get(normalized[-1])
    if multiplier is None:
        raise ValueError(f"Unrecognized block size suffix in '{bs}'")
    value = float(normalized[:-1])
    return int(value * multiplier)


def _load_job(path: Path) -> Dict:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not data.get("jobs"):
        raise ValueError("fio JSON did not contain any jobs")
    return data["jobs"][0]


def _extract_metrics(job: Dict, mode: str) -> MetricValues:
    stats = job.get(mode)
    if stats is None:
        raise ValueError(f"fio job missing '{mode}' stats")

    throughput_mib_s = stats.get("bw_bytes", 0) / (1024 ** 2)
    iops = stats.get("iops", 0)
    latency_ns = stats.get("lat_ns", {}).get("mean")
    latency_ms = (latency_ns / 1_000_000) if latency_ns else 0

    return {
        "throughput_mib_s": throughput_mib_s,
        "iops": iops,
        "latency_ms": latency_ms,
    }


def _discover_clusters(results_dir: Path) -> List[Path]:
    return sorted([p for p in results_dir.iterdir() if p.is_dir()])


def gather_metrics(results_dir: Path) -> Tuple[List[str], List[str], Dict[str, Dict[str, Dict[str, MetricValues]]]]:
    clusters = _discover_clusters(results_dir)
    if not clusters:
        raise FileNotFoundError(f"No cluster subdirectories found in {results_dir}")

    modes = {"read", "write"}
    metrics: Dict[str, Dict[str, Dict[str, MetricValues]]] = {mode: defaultdict(dict) for mode in modes}
    block_sizes: set[str] = set()

    for cluster_path in clusters:
        cluster_name = cluster_path.name
        for mode in modes:
            pattern = f"fio-{mode}-*.json"
            for json_file in sorted(cluster_path.glob(pattern)):
                block_size = json_file.stem.split("-")[-1]
                block_sizes.add(block_size)
                job = _load_job(json_file)
                metrics[mode][cluster_name][block_size] = _extract_metrics(job, mode)

    if not block_sizes:
        raise FileNotFoundError(f"No fio JSON files discovered under {results_dir}")

    ordered_block_sizes = sorted(block_sizes, key=_parse_block_size)
    cluster_names = [path.name for path in clusters]
    return cluster_names, ordered_block_sizes, metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Plot comparison charts from fio result directories")
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path("fio-results"),
        help="Directory containing per-cluster fio results (each subdir should have fio-*.json)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("fio-results") / "fio-comparison.png",
        help="Path to write the generated PNG plot",
    )
    parser.add_argument(
        "--separate",
        action="store_true",
        help="Write separate PNG files for each metric (write/read × throughput, iops, latency)",
    )
    return parser


def _plot_metric(ax, block_sizes: List[str], cluster_names: List[str], metrics: Dict[str, Dict[str, Dict[str, MetricValues]]], mode: str, metric_key: str,
                 title: str, ylabel: str, yscale: str | None = None) -> None:
    x_positions = list(range(len(block_sizes)))
    num_clusters = len(cluster_names)
    bar_width = 0.8 / max(num_clusters, 1)

    for cluster_index, cluster in enumerate(cluster_names):
        cluster_metrics = metrics.get(mode, {}).get(cluster, {})
        values = [cluster_metrics.get(bs, {}).get(metric_key, 0) for bs in block_sizes]
        offsets = [x + (cluster_index - (num_clusters - 1) / 2) * bar_width for x in x_positions]
        # Always set a label so legend can be created for any metric
        ax.bar(offsets, values, width=bar_width, label=cluster)

    ax.set_xticks(x_positions)
    ax.set_xticklabels(block_sizes, rotation=45)
    ax.set_title(title)
    ax.set_ylabel(ylabel)
    # If caller requested a specific scale, use it. Otherwise, auto-switch to
    # log for metrics that span many orders of magnitude so tiny values remain visible.
    if yscale:
        ax.set_yscale(yscale)
    else:
        # compute dynamic range across clusters
        all_vals = []
        for cluster in cluster_names:
            cm = metrics.get(mode, {}).get(cluster, {})
            all_vals.extend([cm.get(bs, {}).get(metric_key, 0) for bs in block_sizes])
        if all_vals:
            maxv = max(all_vals)
            minv = min([v for v in all_vals if v > 0] or [0])
            if maxv > 0 and minv > 0 and maxv / minv > 1000:
                ax.set_yscale("log")


def create_plot(cluster_names: List[str], block_sizes: List[str], metrics: Dict[str, Dict[str, Dict[str, MetricValues]]], output: Path) -> None:
    # Default combined 2x3 layout (kept for backwards compatibility)
    fig, axes = plt.subplots(2, 3, figsize=(16, 9), sharex="col")
    fig.suptitle("Azure Blob CSI fio comparison across cluster types")

    subplot_specs = [
        (0, 0, "write", "throughput_mib_s", "Write throughput", "MiB/s", None),
        (0, 1, "write", "iops", "Write IOPS", "IOPS", None),
        (0, 2, "write", "latency_ms", "Write latency", "Latency (ms)", "log"),
        (1, 0, "read", "throughput_mib_s", "Read throughput", "MiB/s", None),
        (1, 1, "read", "iops", "Read IOPS", "IOPS", None),
        (1, 2, "read", "latency_ms", "Read latency", "Latency (ms)", "log"),
    ]

    for row, col, mode, metric_key, title, ylabel, yscale in subplot_specs:
        ax = axes[row][col]
        _plot_metric(ax, block_sizes, cluster_names, metrics, mode, metric_key, title, ylabel, yscale)

    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper right")

    fig.tight_layout(rect=(0, 0, 0.98, 0.96))
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=150)
    print(f"Wrote {output}")


def create_separate_plots(cluster_names: List[str], block_sizes: List[str], metrics: Dict[str, Dict[str, Dict[str, MetricValues]]], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    specs = [
        ("write", "throughput_mib_s", "Write throughput", "MiB_s", None),
        # IOPS vary across many orders; log scale helps see small values after large ones
        ("write", "iops", "Write IOPS", "IOPS", "log"),
        ("write", "latency_ms", "Write latency", "Latency_ms", "log"),
        ("read", "throughput_mib_s", "Read throughput", "MiB_s", None),
        ("read", "iops", "Read IOPS", "IOPS", "log"),
        ("read", "latency_ms", "Read latency", "Latency_ms", "log"),
    ]

    for mode, metric_key, title, short, yscale in specs:
        fig, ax = plt.subplots(1, 1, figsize=(10, 5))
        _plot_metric(ax, block_sizes, cluster_names, metrics, mode, metric_key, title, short, yscale)
        # Ensure legend is shown for single-metric plots
        ax.legend()
        out_path = output_dir / f"fio-comparison-{mode}-{short}.png"
        fig.tight_layout()
        fig.savefig(out_path, dpi=150)
        plt.close(fig)
        print(f"Wrote {out_path}")


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    cluster_names, block_sizes, metrics = gather_metrics(args.results_dir)
    if getattr(args, "separate", False):
        create_separate_plots(cluster_names, block_sizes, metrics, args.output.parent if args.output.is_file() else args.output)
    else:
        create_plot(cluster_names, block_sizes, metrics, args.output)


if __name__ == "__main__":  # pragma: no cover
    main()
