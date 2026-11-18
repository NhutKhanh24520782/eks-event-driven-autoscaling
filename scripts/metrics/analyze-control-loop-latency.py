#!/usr/bin/env python3
"""Correlate API/worker logs and sampled Kubernetes state into experiment CSVs."""

import argparse
import csv
import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path


JOB_ID_RE = re.compile(r"\bjob_id=([^\s,]+)")
FIELD_RE = re.compile(r"\b([a-z_]+)=([^\s,]+)")


def parse_timestamp(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def read_log(path, jobs, log_type):
    if not path.exists():
        return
    with path.open(encoding="utf-8", errors="replace") as log_file:
        for line in log_file:
            job_match = JOB_ID_RE.search(line)
            if not job_match:
                continue
            job_id = job_match.group(1)
            fields = dict(FIELD_RE.findall(line))
            entry = jobs.setdefault(job_id, {"starts": [], "successes": []})
            if log_type == "api" and "[SQS SENT]" in line:
                t0 = parse_timestamp(fields.get("api_received_at"))
                t1 = parse_timestamp(fields.get("enqueued_at"))
                if t0:
                    entry.setdefault("t0_candidates", []).append(t0)
                if t1:
                    entry.setdefault("t1_candidates", []).append(t1)
            elif log_type == "worker" and "[JOB START]" in line:
                started = parse_timestamp(fields.get("timestamp"))
                if started:
                    entry["starts"].append(started)
            elif log_type == "worker" and "[JOB SUCCESS]" in line:
                completed = parse_timestamp(fields.get("completed_at"))
                duration = fields.get("duration_ms")
                if completed:
                    entry["successes"].append({
                        "completed": completed,
                        "duration_ms": float(duration) if duration and duration.replace(".", "", 1).isdigit() else None,
                    })


def first_timestamp(values):
    return min(values) if values else None


def iso_or_empty(value):
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z") if value else ""


def interval_ms(start, end):
    if not start or not end:
        return None
    if end < start:
        return None
    return round((end - start).total_seconds() * 1000, 3)


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def read_run_events(path):
    events = {}
    if not path.exists():
        return events
    with path.open(newline="", encoding="utf-8") as event_file:
        for row in csv.DictReader(event_file):
            mark = row.get("mark", "").strip()
            timestamp = parse_timestamp(row.get("timestamp", "").strip())
            if mark and timestamp:
                events.setdefault(mark, []).append({
                    "timestamp": timestamp,
                    "source": row.get("source", "").strip(),
                    "uncertainty_ms": row.get("uncertainty_ms", "").strip(),
                })
    return events


def replica_scale_time(path):
    if not path.exists():
        return None
    samples = []
    with path.open(encoding="utf-8", errors="replace") as sample_file:
        next(sample_file, None)
        for line in sample_file:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            timestamp = parse_timestamp(parts[0])
            desired_match = re.search(r"\d+", parts[1])
            if timestamp and desired_match:
                samples.append((timestamp, int(desired_match.group(0))))
    if len(samples) < 2:
        return None
    baseline = samples[0][1]
    return next((timestamp for timestamp, desired in samples[1:] if desired > baseline), None)


def read_pods(path):
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data.get("items", [])


def first_new_pod(before_path, after_path, observations_path, run_started):
    before_pods = read_pods(before_path)
    after_pods = read_pods(after_path)
    old_names = {
        pod.get("metadata", {}).get("name")
        for pod in (before_pods or [])
    }
    candidates = []
    if observations_path.exists():
        latest_by_name = {}
        with observations_path.open(encoding="utf-8", errors="replace") as observations:
            next(observations, None)
            for line in observations:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 6:
                    continue
                _, name, created_text, ready_status, ready_text, node = parts[:6]
                created = parse_timestamp(created_text)
                if not created or name in old_names or (run_started and created < run_started):
                    continue
                ready = parse_timestamp(ready_text) if ready_status == "True" else None
                previous = latest_by_name.get(name)
                if previous is None or (ready and not previous[1]):
                    latest_by_name[name] = (created, ready, name, node)
        candidates.extend(latest_by_name.values())

    if not candidates and after_pods:
        for pod in after_pods:
            name = pod.get("metadata", {}).get("name")
            if name in old_names or pod.get("metadata", {}).get("labels", {}).get("app") != "worker-service":
                continue
            created = parse_timestamp(pod.get("metadata", {}).get("creationTimestamp"))
            if not created or (run_started and created < run_started):
                continue
            ready = next((
                parse_timestamp(condition.get("lastTransitionTime"))
                for condition in pod.get("status", {}).get("conditions", [])
                if condition.get("type") == "Ready" and condition.get("status") == "True"
            ), None)
            node = pod.get("spec", {}).get("nodeName", "")
            candidates.append((created, ready, name, node))
    return min(candidates, key=lambda item: item[0]) if candidates else (None, None, "", "")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence_dir", type=Path, help="directory created by the collector")
    args = parser.parse_args()
    directory = args.evidence_dir
    jobs = {}

    read_log(directory / "api.log", jobs, "api")
    read_log(directory / "worker.log", jobs, "worker")
    run_id = ""
    run_manifest = directory / "run.txt"
    if run_manifest.exists():
        for line in run_manifest.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("run_id="):
                run_id = line.split("=", 1)[1]
                break
    if run_id:
        jobs = {job_id: entry for job_id, entry in jobs.items() if run_id in job_id}
    run_events = read_run_events(directory / "run-events.csv")

    job_rows = []
    samples = {
        "api_to_sqs_ms": [],
        "worker_processing_ms": [],
        "job_end_to_end_ms": [],
    }
    for job_id, entry in sorted(jobs.items()):
        t0 = first_timestamp(entry.get("t0_candidates", []))
        t1 = first_timestamp(entry.get("t1_candidates", []))
        successes = sorted(entry["successes"], key=lambda item: item["completed"])
        success = successes[0] if successes else None
        t6 = success["completed"] if success else None
        api_to_sqs = interval_ms(t0, t1)
        end_to_end = interval_ms(t0, t6)
        processing = success["duration_ms"] if success else None
        if api_to_sqs is not None:
            samples["api_to_sqs_ms"].append(api_to_sqs)
        if end_to_end is not None:
            samples["job_end_to_end_ms"].append(end_to_end)
        if processing is not None:
            samples["worker_processing_ms"].append(processing)
        job_rows.append({
            "job_id": job_id,
            "T0_api_received_utc": iso_or_empty(t0),
            "T1_sqs_ack_utc": iso_or_empty(t1),
            "T6_success_utc": iso_or_empty(t6),
            "api_to_sqs_ms": api_to_sqs if api_to_sqs is not None else "",
            "worker_processing_ms": processing if processing is not None else "",
            "job_end_to_end_ms": end_to_end if end_to_end is not None else "",
            "missing_marks": ",".join(mark for mark, value in (("T0", t0), ("T1", t1), ("T6", t6)) if not value),
        })

    with (directory / "job-latencies.csv").open("w", newline="", encoding="utf-8") as output_file:
        columns = list(job_rows[0].keys()) if job_rows else [
            "job_id", "T0_api_received_utc", "T1_sqs_ack_utc", "T6_success_utc",
            "api_to_sqs_ms", "worker_processing_ms", "job_end_to_end_ms", "missing_marks",
        ]
        writer = csv.DictWriter(output_file, fieldnames=columns)
        writer.writeheader()
        writer.writerows(job_rows)

    scale_time = replica_scale_time(directory / "replicas.tsv")
    t2_entry = min(run_events.get("T2", []), key=lambda item: item["timestamp"], default=None)
    t3_entry = min(run_events.get("T3", []), key=lambda item: item["timestamp"], default=None)
    t3_time = t3_entry["timestamp"] if t3_entry else scale_time
    sample_interval_ms = ""
    if run_manifest.exists():
        for line in run_manifest.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("sample_interval_seconds="):
                sample_interval_ms = str(float(line.split("=", 1)[1]) * 1000)
                break
    run_started = None
    if run_manifest.exists():
        for line in run_manifest.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("started_at="):
                run_started = parse_timestamp(line.split("=", 1)[1])
                break
    t4, t5, new_pod_name, new_pod_node = first_new_pod(
        directory / "worker-pods-before.json",
        directory / "worker-pods.json",
        directory / "worker-pod-observations.tsv",
        run_started,
    )
    first_t1 = min(
        (parse_timestamp(row["T1_sqs_ack_utc"]) for row in job_rows if row["T1_sqs_ack_utc"]),
        default=None,
    )
    t2 = t2_entry["timestamp"] if t2_entry else None
    run_intervals = {
        "first_enqueue_to_t2_ms": interval_ms(first_t1, t2),
        "t2_to_t3_ms": interval_ms(t2, t3_time),
        "t3_to_t4_ms": interval_ms(t3_time, t4),
        "t4_to_t5_ms": interval_ms(t4, t5),
        "first_enqueue_to_ready_ms": interval_ms(first_t1, t5),
    }
    run_row = {
        "T2_keda_observed_utc": iso_or_empty(t2),
        "T2_source": t2_entry["source"] if t2_entry else "",
        "T2_uncertainty_ms": t2_entry["uncertainty_ms"] if t2_entry else "",
        "T3_desired_replica_increase_observed_utc": iso_or_empty(t3_time),
        "T3_source": t3_entry["source"] if t3_entry else ("1-second replica sample" if scale_time else ""),
        "T3_uncertainty_ms": t3_entry["uncertainty_ms"] if t3_entry else (sample_interval_ms if scale_time else ""),
        "T4_worker_pod_name": new_pod_name,
        "T4_worker_node": new_pod_node,
        "T4_first_new_worker_pod_created_utc": iso_or_empty(t4),
        "T5_first_new_worker_pod_ready_utc": iso_or_empty(t5),
        **{name: value if value is not None else "" for name, value in run_intervals.items()},
    }
    with (directory / "run-latencies.csv").open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=list(run_row.keys()))
        writer.writeheader()
        writer.writerow(run_row)

    with (directory / "latency-summary.csv").open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=["interval", "count", "min_ms", "p50_ms", "p90_ms", "p95_ms", "max_ms"])
        writer.writeheader()
        for name, values in samples.items():
            writer.writerow({
                "interval": name,
                "count": len(values),
                "min_ms": min(values) if values else "",
                "p50_ms": percentile(values, 0.50) if values else "",
                "p90_ms": percentile(values, 0.90) if values else "",
                "p95_ms": percentile(values, 0.95) if values else "",
                "max_ms": max(values) if values else "",
            })

    missing = {
        "jobs_without_T0": sum(not row["T0_api_received_utc"] for row in job_rows),
        "jobs_without_T1": sum(not row["T1_sqs_ack_utc"] for row in job_rows),
        "jobs_without_T6": sum(not row["T6_success_utc"] for row in job_rows),
        "T2_unavailable": t2 is None,
        "T3_unavailable": t3_time is None,
        "T4_unavailable": t4 is None,
        "T5_unavailable": t5 is None,
        "T3_sample_observed_after_T4": bool(
            not t3_entry and scale_time and t4 and scale_time > t4
        ),
    }
    (directory / "latency-analysis.json").write_text(
        json.dumps({"run_id": run_id, "job_count": len(job_rows), "missing_events": missing}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Analyzed {len(job_rows)} correlated jobs in {directory}")
    print(f"T2 observed: {'yes' if t2 else 'no'}; T3-T5 are derived from sampled Kubernetes state.")
    print("Wrote job-latencies.csv, run-latencies.csv, latency-summary.csv, latency-analysis.json.")


if __name__ == "__main__":
    main()
