#!/usr/bin/env python3
"""Utilities for parsing and plotting netperf/qperf CSV exports."""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple


@dataclass
class Series:
    """Represents a single scenario series parsed from a CSV row."""

    label: str
    sizes: List[int]
    bandwidth_mb: List[float]
    latency_us: List[float]


_LABEL_SANITIZE_RE = re.compile(r"[^0-9A-Za-z]+")
_BW_RE = re.compile(r"bw\s*=\s*([0-9.+-eE]+)\s*([A-Za-z]+/sec)", re.IGNORECASE)
_LAT_RE = re.compile(r"latency\s*=\s*([0-9.+-eE]+)\s*([A-Za-zµμ]+)", re.IGNORECASE)


def _sanitize_label(label: str) -> str:
    sanitized = _LABEL_SANITIZE_RE.sub("_", label.strip())
    sanitized = sanitized.strip("_").lower()
    return sanitized or "series"


def _parse_sizes(cells: Sequence[str]) -> List[int]:
    sizes: List[int] = []
    for cell in cells:
        text = cell.strip().rstrip(",")
        if not text:
            continue
        try:
            value = float(text)
        except ValueError:
            continue
        sizes.append(int(value))
    return sizes


def _convert_bandwidth(value: float, unit: str) -> float:
    unit = unit.lower()
    if unit.startswith("gb"):
        return value * 1024.0
    if unit.startswith("mb"):
        return value
    if unit.startswith("kb"):
        return value / 1024.0
    if unit.startswith("b"):
        # Convert bytes/sec to MiB/s.
        return value / (1024.0 * 1024.0)
    return value


def _convert_latency(value: float, unit: str) -> float:
    unit = unit.lower()
    if unit.startswith("ms"):
        return value * 1000.0
    if unit.startswith("us") or unit.startswith("µs") or unit.startswith("μs"):
        return value
    if unit.startswith("ns"):
        return value / 1000.0
    if unit.startswith("s"):
        return value * 1_000_000.0
    return value


def _parse_metric_cell(cell: str) -> Tuple[float | None, float | None]:
    text = cell.strip()
    if not text:
        return None, None

    if text.startswith("(") and "bw" in text:
        bw_match = _BW_RE.search(text)
        lat_match = _LAT_RE.search(text)
        bandwidth = None
        latency = None
        if bw_match:
            bandwidth = _convert_bandwidth(float(bw_match.group(1)), bw_match.group(2))
        if lat_match:
            latency = _convert_latency(float(lat_match.group(1)), lat_match.group(2))
        return bandwidth, latency

    # Fall back to treating the cell as a raw numeric bandwidth reading.
    try:
        return float(text), None
    except ValueError:
        return None, None


def _parse_row(row: Sequence[str], base_sizes: List[int]) -> Series | None:
    if not row or not row[0].strip():
        return None

    label = row[0].strip()
    data_cells = row[2:]
    sizes: List[int] = []
    bandwidths: List[float] = []
    latencies_collected: List[float] = []
    latency_complete = True

    for size, cell in zip(base_sizes, data_cells):
        bw, lat = _parse_metric_cell(cell)
        if bw is None:
            continue
        sizes.append(size)
        bandwidths.append(bw)
        if lat is None:
            latency_complete = False
        else:
            latencies_collected.append(lat)

    if not bandwidths:
        return None

    latency_us: List[float]
    if latency_complete and len(latencies_collected) == len(bandwidths):
        latency_us = latencies_collected
    else:
        latency_us = []

    return Series(label=label, sizes=sizes, bandwidth_mb=bandwidths, latency_us=latency_us)


def parse_csv(path: Path) -> List[Series]:
    with path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.reader(fh, skipinitialspace=True)
        header = next(reader, None)
        if header is None:
            raise ValueError(f"CSV file {path} is empty")
        base_sizes = _parse_sizes(header[2:])
        series_list: List[Series] = []
        for row in reader:
            series = _parse_row(row, base_sizes)
            if series:
                series_list.append(series)
    return series_list
