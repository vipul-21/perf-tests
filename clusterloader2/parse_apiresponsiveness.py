import os
import json
import csv
from collections import defaultdict
from datetime import datetime

# Thresholds
LATENCY_THRESHOLD_MUTATING = 1000  # ms
LATENCY_THRESHOLD_SCOPE = {
    "resource": 1000,
    "namespace": 30000,
    "cluster": 30000,
}

# HTTP Verbs
MUTATING_VERBS = {"POST", "PUT", "DELETE", "PATCH"}
READ_VERBS = {"GET", "LIST"}

# Root results directory
ROOT_DIR = "results/logs"

def process_file(filepath, subdir_name, mutating_rows, read_rows,
                 mutating_stats_by_subdir, read_stats_by_subdir, all_items):
    with open(filepath, "r") as f:
        content = json.load(f)
        for item in content.get("dataItems", []):
            all_items.append(item)
            data = item.get("data", {})
            labels = item.get("labels", {})

            perc99 = data.get("Perc99", 0.0)
            slow_count = int(labels.get("SlowCount", "0"))
            count = int(labels.get("Count", "0"))
            verb = labels.get("Verb", "").upper()
            resource = labels.get("Resource", "")
            scope = labels.get("Scope", "").lower()

            if count == 0:
                continue

            if verb in MUTATING_VERBS:
                mutating_stats_by_subdir[subdir_name]["weighted_sum"] += perc99 * count
                mutating_stats_by_subdir[subdir_name]["total_count"] += count

                if slow_count > 0 and perc99 > LATENCY_THRESHOLD_MUTATING:
                    mutating_rows.append([subdir_name, resource, verb, slow_count, round(perc99, 2)])

            elif verb in READ_VERBS:
                threshold = LATENCY_THRESHOLD_SCOPE.get(scope, LATENCY_THRESHOLD_SCOPE["resource"])
                read_stats_by_subdir[subdir_name]["weighted_sum"] += perc99 * count
                read_stats_by_subdir[subdir_name]["total_count"] += count

                if slow_count > 0 and perc99 > threshold:
                    read_rows.append([subdir_name, resource, scope, verb, slow_count, round(perc99, 2)])

def summarize_test(test_path):
    mutating_rows = []
    read_rows = []
    baseline_mutating_rows = []
    baseline_read_rows = []
    all_workload_items = []
    all_baseline_items = []

    mutating_stats_by_subdir = defaultdict(lambda: {"weighted_sum": 0.0, "total_count": 0})
    read_stats_by_subdir = defaultdict(lambda: {"weighted_sum": 0.0, "total_count": 0})
    baseline_mutating_stats_by_subdir = defaultdict(lambda: {"weighted_sum": 0.0, "total_count": 0})
    baseline_read_stats_by_subdir = defaultdict(lambda: {"weighted_sum": 0.0, "total_count": 0})

    for root, dirs, files in os.walk(test_path):
        for file in files:
            if file.startswith("APIResponsiveness") and file.endswith(".json"):
                filepath = os.path.join(root, file)
                subdir_name = os.path.relpath(root, test_path)
                if "Baseline" in file:
                    process_file(filepath, subdir_name, baseline_mutating_rows, baseline_read_rows,
                                 baseline_mutating_stats_by_subdir, baseline_read_stats_by_subdir, all_baseline_items)
                else:
                    process_file(filepath, subdir_name, mutating_rows, read_rows,
                                 mutating_stats_by_subdir, read_stats_by_subdir, all_workload_items)

    summary_path = os.path.join(test_path, "APIResponsivenessTestSummary.log")
    with open(summary_path, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)

        # Mutating verbs
        total_mutating = sum(row[3] for row in mutating_rows)
        writer.writerow(["Mutating Verbs: Total Queries > 1s", total_mutating])
        writer.writerow(["Subdir", "Resource", "Verb", "SlowCount", "Perc99"])
        for row in mutating_rows:
            writer.writerow(row)

        writer.writerow([])
        writer.writerow(["Weighted Average Perc99 per Subdir (Mutating)"])
        writer.writerow(["Subdir", "WeightedAvgPerc99(ms)"])
        for subdir, stats in sorted(mutating_stats_by_subdir.items()):
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                writer.writerow([subdir, round(avg, 2)])

        writer.writerow([])

        # Read verbs
        total_read = sum(row[4] for row in read_rows)
        writer.writerow(["Read Verbs: Total Queries Exceeding Scope-Specific Limit", total_read])
        writer.writerow(["Subdir", "Resource", "Scope", "Verb", "SlowCount", "Perc99"])
        for row in read_rows:
            writer.writerow(row)

        writer.writerow([])
        writer.writerow(["Weighted Average Perc99 per Subdir (Read)"])
        writer.writerow(["Subdir", "WeightedAvgPerc99(ms)"])
        for subdir, stats in sorted(read_stats_by_subdir.items()):
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                writer.writerow([subdir, round(avg, 2)])

    timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    artifacts_dir = os.path.join(test_path, "artifacts")
    
    if all_workload_items and mutating_stats_by_subdir:
        workload_summary_items = []
        for subdir, stats in mutating_stats_by_subdir.items():
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                workload_summary_items.append({
                    "data": {
                        "WeightedAvgPerc99": round(avg, 2)
                    },
                    "unit": "ms",
                    "labels": {
                        "Type": "Mutating",
                        "Subdir": subdir
                    }
                })
        
        for subdir, stats in read_stats_by_subdir.items():
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                workload_summary_items.append({
                    "data": {
                        "WeightedAvgPerc99": round(avg, 2)
                    },
                    "unit": "ms",
                    "labels": {
                        "Type": "Read",
                        "Subdir": subdir
                    }
                })
        
        if workload_summary_items:
            workload_json_path = os.path.join(artifacts_dir, f"APIResponsivenessPrometheus_Summary_{timestamp}.json")
            os.makedirs(artifacts_dir, exist_ok=True)
            with open(workload_json_path, "w") as f:
                json.dump({"version": "v1", "dataItems": workload_summary_items}, f, indent=2)

    baseline_summary_path = os.path.join(test_path, "APIResponsivenessBaselineTestSummary.log")
    with open(baseline_summary_path, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)

        # Baseline Mutating verbs
        total_baseline_mutating = sum(row[3] for row in baseline_mutating_rows)
        writer.writerow(["Baseline Mutating Verbs: Total Queries > 1s", total_baseline_mutating])
        writer.writerow(["Subdir", "Resource", "Verb", "SlowCount", "Perc99"])
        for row in baseline_mutating_rows:
            writer.writerow(row)

        writer.writerow([])
        writer.writerow(["Weighted Average Perc99 per Subdir (Baseline Mutating)"])
        writer.writerow(["Subdir", "WeightedAvgPerc99(ms)"])
        for subdir, stats in sorted(baseline_mutating_stats_by_subdir.items()):
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                writer.writerow([subdir, round(avg, 2)])

        writer.writerow([])

        # Baseline Read verbs
        total_baseline_read = sum(row[4] for row in baseline_read_rows)
        writer.writerow(["Baseline Read Verbs: Total Queries Exceeding Scope-Specific Limit", total_baseline_read])
        writer.writerow(["Subdir", "Resource", "Scope", "Verb", "SlowCount", "Perc99"])
        for row in baseline_read_rows:
            writer.writerow(row)

        writer.writerow([])
        writer.writerow(["Weighted Average Perc99 per Subdir (Baseline Read)"])
        writer.writerow(["Subdir", "WeightedAvgPerc99(ms)"])
        for subdir, stats in sorted(baseline_read_stats_by_subdir.items()):
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                writer.writerow([subdir, round(avg, 2)])

    if all_baseline_items and baseline_mutating_stats_by_subdir:
        baseline_summary_items = []
        for subdir, stats in baseline_mutating_stats_by_subdir.items():
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                baseline_summary_items.append({
                    "data": {
                        "WeightedAvgPerc99": round(avg, 2)
                    },
                    "unit": "ms",
                    "labels": {
                        "Type": "Mutating",
                        "Subdir": subdir
                    }
                })
        
        for subdir, stats in baseline_read_stats_by_subdir.items():
            if stats["total_count"] > 0:
                avg = stats["weighted_sum"] / stats["total_count"]
                baseline_summary_items.append({
                    "data": {
                        "WeightedAvgPerc99": round(avg, 2)
                    },
                    "unit": "ms",
                    "labels": {
                        "Type": "Read",
                        "Subdir": subdir
                    }
                })
        
        if baseline_summary_items:
            baseline_json_path = os.path.join(artifacts_dir, f"APIResponsivenessPrometheus_Baseline_Summary_{timestamp}.json")
            os.makedirs(artifacts_dir, exist_ok=True)
            with open(baseline_json_path, "w") as f:
                json.dump({"version": "v1", "dataItems": baseline_summary_items}, f, indent=2)

def main():
    for job_dir in os.listdir(ROOT_DIR):
        job_path = os.path.join(ROOT_DIR, job_dir)
        if os.path.isdir(job_path):
            for build_dir in os.listdir(job_path):
                build_path = os.path.join(job_path, build_dir)
                if os.path.isdir(build_path) and build_dir.isdigit():
                    summarize_test(build_path)

if __name__ == "__main__":
    main()