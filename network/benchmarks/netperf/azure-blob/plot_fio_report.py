#!/usr/bin/env python3
"""Plot high-level metrics from an fio JSON report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, Iterable

import matplotlib.pyplot as plt

plt.switch_backend("Agg")


def _extract_latency_percentiles(percentiles: Dict[str, float], keys: Iterable[str]) -> Dict[str, float]:
    result: Dict[str, float] = {}
    for key in keys:
        value_ns = percentiles.get(key)
        if value_ns is None:
            continue
        result[f"P{key.split('.')[0] if '.' in key else key}"] = value_ns / 1_000_000  # ns -> ms
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Render summary plot from fio JSON output")
    parser.add_argument("input", type=Path, help="Path to fio JSON report")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("fio-report.png"),
        help="Where to write the generated plot (PNG)",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()

    with args.input.open("r", encoding="utf-8") as fh:
        data = json.load(fh)

    if not data.get("jobs"):
        raise ValueError("fio JSON did not contain any jobs")

    job = data["jobs"][0]
    write_stats = job["write"]
    options = job.get("job options", {})

    bw_mib_s = write_stats["bw_bytes"] / (1024**2)
    iops = write_stats["iops"]
    avg_latency_ms = write_stats.get("lat_ns", {}).get("mean", 0) / 1_000_000

    percentile_keys = ("50.000000", "95.000000", "99.000000", "99.900000")
    latency_percentiles = _extract_latency_percentiles(
        write_stats.get("clat_ns", {}).get("percentile", {}), percentile_keys
    )

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle(
        f"fio write benchmark — {options.get('name', job.get('jobname', 'job'))}\n"
        f"bs={options.get('bs', 'n/a')} | iodepth={options.get('iodepth', 'n/a')} | size={options.get('size', 'n/a')}"
    )

    # Throughput and IOPS subplot with shared x-axis labels
    metrics = ["Throughput (MiB/s)", "IOPS", "Avg latency (ms)"]
    values = [bw_mib_s, iops, avg_latency_ms]
    colors = ["#4c72b0", "#55a868", "#c44e52"]

    axes[0].bar(metrics, values, color=colors)
    axes[0].set_ylabel("Value")
    axes[0].set_title("Aggregate performance")
    for idx, value in enumerate(values):
        axes[0].text(idx, value, f"{value:,.1f}", ha="center", va="bottom", fontsize=10)

    # Latency percentile subplot
    if latency_percentiles:
        labels = list(latency_percentiles.keys())
        percentile_values = [latency_percentiles[label] for label in labels]
        axes[1].bar(labels, percentile_values, color="#dd8452")
        axes[1].set_ylabel("Latency (ms)")
        axes[1].set_title("Completion latency percentiles")
        axes[1].set_yscale("log")
        for idx, value in enumerate(percentile_values):
            axes[1].text(idx, value, f"{value:,.2f}", ha="center", va="bottom", fontsize=10)
    else:
        axes[1].axis("off")
        axes[1].text(0.5, 0.5, "No latency percentiles available", ha="center", va="center")

    fig.tight_layout(rect=(0, 0, 1, 0.94))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=150)
    print(f"Wrote {args.output}")


if __name__ == "__main__":  # pragma: no cover
    main()
