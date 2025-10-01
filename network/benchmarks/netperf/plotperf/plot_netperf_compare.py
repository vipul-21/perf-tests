#!/usr/bin/env python3
"""Generate comparison plots for multiple netperf/qperf CSV runs.

This script builds on ``plot_netperf`` by overlaying the bandwidth and latency
series for identically named scenarios (rows) from two different CSV exports.
It is intended for quick side-by-side comparisons, e.g. eBPF vs legacy host
routing results.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import matplotlib.pyplot as plt

# Ensure the package root is on sys.path so `from plotperf...` works when this
# script is invoked as `python plotperf/plot_netperf_compare.py` (sys.path[0]
# would otherwise be the `plotperf/` directory itself).
import sys
from pathlib import Path as _Path
sys.path.insert(0, str(_Path(__file__).resolve().parent.parent))

from plotperf.plot_netperf import Series, _sanitize_label, parse_csv  # type: ignore


@dataclass
class Pair:
    label: str
    first: Series
    second: Series

    @property
    def common_sizes(self) -> List[int]:
        return _align_sizes(self.first.sizes, self.second.sizes)

    def bandwidth_pair(self) -> Tuple[List[int], List[float], List[float]]:
        sizes = self.common_sizes
        count = len(sizes)
        return (
            sizes,
            self.first.bandwidth_mb[:count],
            self.second.bandwidth_mb[:count],
        )

    def latency_pair(self) -> Tuple[List[int], List[float], List[float]] | None:
        if not self.first.latency_us or not self.second.latency_us:
            return None
        sizes = self.common_sizes
        count = len(sizes)
        first_lat = self.first.latency_us[:count]
        second_lat = self.second.latency_us[:count]
        if not first_lat or not second_lat:
            return None
        min_len = min(len(first_lat), len(second_lat))
        sizes = sizes[:min_len]
        return sizes, first_lat[:min_len], second_lat[:min_len]


def _align_sizes(first: Iterable[int], second: Iterable[int]) -> List[int]:
    first_list = list(first)
    second_set = set(second)
    aligned = [size for size in first_list if size in second_set]
    if aligned:
        return aligned
    # Fall back to positional alignment if headers differ yet counts match.
    return first_list[: min(len(first_list), len(second_set))]


def _build_pairs(first_csv: Path, second_csv: Path) -> Dict[str, Pair]:
    first_series = {series.label: series for series in parse_csv(first_csv)}
    second_series = {series.label: series for series in parse_csv(second_csv)}
    pairs: Dict[str, Pair] = {}
    for label, series in first_series.items():
        if label not in second_series:
            continue
        pairs[label] = Pair(label=label, first=series, second=second_series[label])
    return pairs


def _plot_pair(pair: Pair, names: Tuple[str, str], output_dir: Path) -> List[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated: List[Path] = []
    safe_label = _sanitize_label(pair.label)

    sizes, first_bw, second_bw = pair.bandwidth_pair()
    plt.figure(figsize=(8, 4))
    plt.plot(sizes, first_bw, marker="o", label=names[0])
    plt.plot(sizes, second_bw, marker="s", label=names[1])
    plt.xlabel("Message size / MSS (bytes)")
    plt.ylabel("Bandwidth (MB/sec)")
    plt.title(f"{pair.label} - Bandwidth")
    plt.grid(True, which="both", linestyle="--", linewidth=0.5)
    plt.xscale("log", base=2)
    plt.legend()
    plt.tight_layout()
    bw_path = output_dir / f"{safe_label}_bandwidth_compare.png"
    plt.savefig(bw_path, dpi=160)
    generated.append(bw_path)
    plt.close()

    latency = pair.latency_pair()
    if latency:
        sizes, first_lat, second_lat = latency
        plt.figure(figsize=(8, 4))
        plt.plot(sizes, first_lat, marker="o", label=names[0])
        plt.plot(sizes, second_lat, marker="s", label=names[1])
        plt.xlabel("Message size / MSS (bytes)")
        plt.ylabel("Latency (µs)")
        plt.title(f"{pair.label} - Latency")
        plt.grid(True, which="both", linestyle="--", linewidth=0.5)
        plt.xscale("log", base=2)
        plt.legend()
        plt.tight_layout()
        lat_path = output_dir / f"{safe_label}_latency_compare.png"
        plt.savefig(lat_path, dpi=160)
        generated.append(lat_path)
        plt.close()

    return generated


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare two netperf CSV runs and plot overlay charts")
    parser.add_argument("first_csv", type=Path, help="CSV for baseline run (e.g. BPF mode)")
    parser.add_argument("second_csv", type=Path, help="CSV for comparison run (e.g. legacy mode)")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("plots_compare"),
        help="Directory where comparison PNG charts will be written",
    )
    parser.add_argument(
        "--names",
        nargs=2,
        metavar=("FIRST", "SECOND"),
        help="Display names for the two runs (defaults to CSV stem names)",
    )
    args = parser.parse_args()

    display_names = tuple(args.names) if args.names else (args.first_csv.stem, args.second_csv.stem)

    pairs = _build_pairs(args.first_csv, args.second_csv)
    if not pairs:
        parser.error("No matching scenario labels were found across the two CSV files.")

    generated: List[Path] = []
    for pair in pairs.values():
        generated.extend(_plot_pair(pair, display_names, args.output))

    print("Generated comparison plots:")
    for path in generated:
        print(f"  {path}")


if __name__ == "__main__":
    main()
