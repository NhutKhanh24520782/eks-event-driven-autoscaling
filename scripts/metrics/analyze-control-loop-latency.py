#!/usr/bin/env python3
"""Correlate per-job API/worker logs and captured Kubernetes scale events."""

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
                client_sent = parse_timestamp(fields.get("client_sent_at"))
                t0 = parse_timestamp(fields.get("api_received_at"))
                t1 = parse_timestamp(fields.get("enqueued_at"))
                if client_sent:
                    entry.setdefault("client_sent_candidates", []).append(client_sent)
                if t0:
                    entry.setdefault("t0_candidates", []).append(t0)
                if t1:
                    entry.setdefault("t1_candidates", []).append(t1)
            elif log_type == "worker" and "[JOB START]" in line:
                started = parse_timestamp(fields.get("timestamp"))
                client_sent = parse_timestamp(fields.get("client_sent_at"))
                worker_match = re.search(r"\[WORKER\s+([^\]]+)\]", line)
                worker_id = worker_match.group(1) if worker_match else fields.get("worker_id", "")
                if started:
                    entry["starts"].append({
                        "started": started,
                        "client_sent": client_sent,
                        "worker_id": worker_id
                    })
                if client_sent:
                    entry.setdefault("client_sent_candidates", []).append(client_sent)
            elif log_type == "worker" and "[JOB SUCCESS]" in line:
                completed = parse_timestamp(fields.get("completed_at"))
                duration = fields.get("duration_ms")
                worker_match = re.search(r"\[WORKER\s+([^\]]+)\]", line)
                worker_id = worker_match.group(1) if worker_match else fields.get("worker_id", "")
                if completed:
                    entry["successes"].append({
                        "completed": completed,
                        "duration_ms": float(duration) if duration and duration.replace(".", "", 1).isdigit() else None,
                        "worker_id": worker_id
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


def signed_interval_ms(start, end):
    if not start or not end:
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
    with path.open(newline="", encoding="utf-8-sig") as event_file:
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


def event_timestamp(event):
    series = event.get("series") or {}
    timestamps = (
        series.get("lastObservedTime"),
        event.get("eventTime"),
        event.get("lastTimestamp"),
        event.get("firstTimestamp"),
        event.get("metadata", {}).get("creationTimestamp"),
    )
    return next((parsed for value in timestamps if (parsed := parse_timestamp(value))), None)


def read_kubernetes_events(directory):
    events = []
    snapshots = (
        directory / "app-events.json",
        directory / "keda-events.json",
    )
    for path in snapshots:
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"Could not read Kubernetes Event snapshot {path}: {error}") from error
        events.extend(data.get("items", []))

    jsonl_path = directory / "kubernetes-events.jsonl"
    if jsonl_path.exists():
        with jsonl_path.open(encoding="utf-8-sig", errors="replace") as event_file:
            for line_number, line in enumerate(event_file, start=1):
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as error:
                    raise ValueError(
                        f"Invalid JSON in {jsonl_path} at line {line_number}: {error}"
                    ) from error
                if isinstance(record.get("items"), list):
                    events.extend(record["items"])
                else:
                    events.append(record.get("event", record))

    unique = {}
    for event in events:
        metadata = event.get("metadata", {})
        event_time = event_timestamp(event)
        if not event_time:
            continue
        key = (metadata.get("uid", ""), event_time.isoformat(), event.get("reason", ""))
        unique[key] = event
    return list(unique.values())


def hpa_scale_event(events, run_started, baseline_replicas):
    candidates = []
    for event in events:
        involved = event.get("involvedObject") or {}
        if involved.get("kind") != "HorizontalPodAutoscaler":
            continue
        if "worker" not in involved.get("name", "").lower():
            continue
        if event.get("reason") != "SuccessfulRescale":
            continue
        message = event.get("message", "")
        new_size = re.search(r"\bNew size:\s*(\d+)", message)
        if not new_size or int(new_size.group(1)) <= baseline_replicas:
            continue
        timestamp = event_timestamp(event)
        if timestamp and (run_started is None or timestamp >= run_started):
            candidates.append((timestamp, event))
    return min(candidates, key=lambda item: item[0]) if candidates else (None, None)


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
        for line in run_manifest.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            line = line.strip()
            if line.startswith("run_id="):
                run_id = line.split("=", 1)[1].strip()
                break
    if run_id:
        jobs = {job_id: entry for job_id, entry in jobs.items() if run_id in job_id}
    run_events = read_run_events(directory / "run-events.csv")

    job_rows = []
    samples = {
        "client_to_api_ms": [],
        "api_to_sqs_ms": [],
        "worker_processing_ms": [],
        "job_end_to_end_ms": [],
    }
    for seq_idx, (job_id, entry) in enumerate(sorted(jobs.items()), start=1):
        client_sent = first_timestamp(entry.get("client_sent_candidates", []))
        api_received = first_timestamp(entry.get("t0_candidates", []))
        t1 = first_timestamp(entry.get("t1_candidates", []))
        successes = sorted(entry["successes"], key=lambda item: item["completed"])
        success = successes[0] if successes else None
        t6 = success["completed"] if success else None
        client_to_api = signed_interval_ms(client_sent, api_received)
        client_to_sqs = interval_ms(client_sent, t1)
        api_to_sqs = interval_ms(api_received, t1)
        end_to_end = interval_ms(client_sent, t6)
        processing = success["duration_ms"] if success else None

        worker_start_info = entry["starts"][0] if entry.get("starts") else None
        if client_sent is None and worker_start_info:
            client_sent = worker_start_info.get("client_sent")
            client_to_api = signed_interval_ms(client_sent, api_received)
            client_to_sqs = interval_ms(client_sent, t1)
            end_to_end = interval_ms(client_sent, t6)
        worker_id = (success.get("worker_id") if success else "") or (worker_start_info.get("worker_id") if worker_start_info else "")
        status = "completed" if success else "in_flight"

        if client_to_api is not None:
            samples["client_to_api_ms"].append(client_to_api)
        if api_to_sqs is not None:
            samples["api_to_sqs_ms"].append(api_to_sqs)
        if end_to_end is not None:
            samples["job_end_to_end_ms"].append(end_to_end)
        if processing is not None:
            samples["worker_processing_ms"].append(processing)
        job_rows.append({
            "seq": seq_idx,
            "job_id": job_id,
            "status": status,
            "worker_id": worker_id,
            "client_sent_at": iso_or_empty(client_sent),
            "api_received_at": iso_or_empty(api_received),
            "enqueued_at": iso_or_empty(t1),
            "client_to_api_ms": client_to_api if client_to_api is not None else "",
            "t1_minus_t0_ms": client_to_sqs if client_to_sqs is not None else "",
            "api_to_sqs_ms": api_to_sqs if api_to_sqs is not None else "",
            "t6_completed": iso_or_empty(t6),
            "worker_duration_ms": processing if processing is not None else "",
            "e2e_latency_ms": end_to_end if end_to_end is not None else "",
        })

    with (directory / "job-latencies.csv").open("w", newline="", encoding="utf-8") as output_file:
        columns = list(job_rows[0].keys()) if job_rows else [
            "seq", "job_id", "status", "worker_id", "client_sent_at", "api_received_at",
            "enqueued_at", "client_to_api_ms", "t1_minus_t0_ms", "api_to_sqs_ms",
            "t6_completed", "worker_duration_ms", "e2e_latency_ms",
        ]
        writer = csv.DictWriter(output_file, fieldnames=columns)
        writer.writeheader()
        writer.writerows(job_rows)

    # Also save as control-loop-latency-evidence.csv for web download
    with (directory / "control-loop-latency-evidence.csv").open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=columns)
        writer.writeheader()
        writer.writerows(job_rows)

    run_started = None
    if run_manifest.exists():
        for line in run_manifest.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            line = line.strip()
            if line.startswith("started_at="):
                run_started = parse_timestamp(line.split("=", 1)[1])
                break
    kubernetes_events = read_kubernetes_events(directory)
    t2_entry = min(run_events.get("T2", []), key=lambda item: item["timestamp"], default=None)
    t3_entry = min(run_events.get("T3", []), key=lambda item: item["timestamp"], default=None)
    replica_samples_path = directory / "replicas.tsv"
    baseline_replicas = 0
    if replica_samples_path.exists():
        with replica_samples_path.open(encoding="utf-8-sig", errors="replace") as replica_file:
            next(replica_file, None)
            for line in replica_file:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[1].isdigit():
                    baseline_replicas = int(parts[1])
                    break
    if t3_entry:
        t3_time = t3_entry["timestamp"]
        t3_source = t3_entry["source"] or "run-events.csv"
        t3_uncertainty = t3_entry["uncertainty_ms"]
        t3_event = None
    else:
        t3_time, t3_event = hpa_scale_event(kubernetes_events, run_started, baseline_replicas)
        t3_source = (
            f"Kubernetes Event: {t3_event.get('involvedObject', {}).get('name')} "
            f"({t3_event.get('reason')})"
            if t3_event else ""
        )
        t3_uncertainty = "1000" if t3_event else ""
    t4, t5, new_pod_name, new_pod_node = first_new_pod(
        directory / "worker-pods-before.json",
        directory / "worker-pods.json",
        directory / "worker-pod-observations.tsv",
        run_started,
    )
    first_t0 = min(
        (parse_timestamp(row["client_sent_at"]) for row in job_rows if row["client_sent_at"]),
        default=None,
    )
    first_t1 = min(
        (parse_timestamp(row["enqueued_at"]) for row in job_rows if row["enqueued_at"]),
        default=None,
    )
    t2 = t2_entry["timestamp"] if t2_entry else None
    t3_time = t3_time if t3_time else None
    t2_source = t2_entry["source"] if t2_entry else ""
    t2_uncertainty = t2_entry["uncertainty_ms"] if t2_entry else ""
    run_intervals = {
        "first_enqueue_to_t2_ms": interval_ms(first_t1, t2),
        "t2_to_t3_ms": interval_ms(t2, t3_time),
        "t3_to_t4_ms": interval_ms(t3_time, t4),
        "t4_to_t5_ms": interval_ms(t4, t5),
        "first_enqueue_to_ready_ms": interval_ms(first_t1, t5),
    }
    run_row = {
        "T2_keda_observed_utc": iso_or_empty(t2),
        "T2_source": t2_source,
        "T2_uncertainty_ms": t2_uncertainty,
        "T3_desired_replica_increase_observed_utc": iso_or_empty(t3_time),
        "T3_source": t3_source,
        "T3_uncertainty_ms": t3_uncertainty,
        "T4_worker_pod_name": new_pod_name,
        "T4_worker_node": new_pod_node,
        "T4_first_new_worker_pod_created_utc": iso_or_empty(t4),
        "T4_source": "Kubernetes Pod metadata.creationTimestamp" if t4 else "",
        "T4_uncertainty_ms": "1000" if t4 else "",
        "T5_first_new_worker_pod_ready_utc": iso_or_empty(t5),
        "T5_source": "Kubernetes Pod Ready condition lastTransitionTime" if t5 else "",
        "T5_uncertainty_ms": "1000" if t5 else "",
        **{name: value if value is not None else "" for name, value in run_intervals.items()},
    }
    with (directory / "run-latencies.csv").open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=list(run_row.keys()))
        writer.writeheader()
        writer.writerow(run_row)

    t3_event_obj = t3_event.get("involvedObject", {}) if t3_event else {}
    scale_event_rows = [
        {
            "mark": "T2",
            "event_name": "KEDA Queue Signal",
            "timestamp_utc": iso_or_empty(t2),
            "elapsed_from_t0_ms": interval_ms(first_t0, t2),
            "source": t2_source or "not captured; record an observed Prometheus/KEDA timestamp in run-events.csv",
            "uncertainty_ms": t2_uncertainty,
            "evidence_status": "captured" if t2 else "unavailable",
            "object": "",
            "reason": "",
            "description": "Leave unavailable unless an actual KEDA signal timestamp was captured."
        },
        {
            "mark": "T3",
            "event_name": "HPA Scale-Up Event",
            "timestamp_utc": iso_or_empty(t3_time),
            "elapsed_from_t0_ms": interval_ms(first_t0, t3_time),
            "source": t3_source or "not captured",
            "uncertainty_ms": t3_uncertainty,
            "evidence_status": "captured" if t3_time else "unavailable",
            "object": t3_event_obj.get("name", ""),
            "reason": t3_event.get("reason", "") if t3_event else "",
            "description": "Kubernetes SuccessfulRescale event for worker HPA, or a timestamp explicitly recorded in run-events.csv."
        },
        {
            "mark": "T4",
            "event_name": "First New Worker Pod Created",
            "timestamp_utc": iso_or_empty(t4),
            "elapsed_from_t0_ms": interval_ms(first_t0, t4),
            "source": "Kubernetes Pod metadata.creationTimestamp" if t4 else "not captured",
            "uncertainty_ms": "1000" if t4 else "",
            "evidence_status": "captured" if t4 else "unavailable",
            "object": new_pod_name,
            "reason": "",
            "description": f"Pod scheduled on {new_pod_node}" if t4 else "No new worker Pod timestamp was captured."
        },
        {
            "mark": "T5",
            "event_name": "First New Worker Pod Ready",
            "timestamp_utc": iso_or_empty(t5),
            "elapsed_from_t0_ms": interval_ms(first_t0, t5),
            "source": "Kubernetes Pod Ready condition lastTransitionTime" if t5 else "not captured",
            "uncertainty_ms": "1000" if t5 else "",
            "evidence_status": "captured" if t5 else "unavailable",
            "object": new_pod_name,
            "reason": "",
            "description": "Timestamp recorded by the Kubernetes Pod status condition."
        },
    ]
    with (directory / "scale-events.csv").open("w", newline="", encoding="utf-8") as output_file:
        fieldnames = [
            "mark", "event_name", "timestamp_utc", "elapsed_from_t0_ms",
            "source", "uncertainty_ms", "evidence_status", "object", "reason", "description",
        ]
        writer = csv.DictWriter(output_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(scale_event_rows)

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
        "jobs_without_T0": sum(not row["client_sent_at"] for row in job_rows),
        "jobs_without_T1": sum(not row["enqueued_at"] for row in job_rows),
        "jobs_without_T6": sum(not row["t6_completed"] for row in job_rows),
        "jobs_with_negative_client_to_api_ms": sum(
            row["client_to_api_ms"] != "" and row["client_to_api_ms"] < 0
            for row in job_rows
        ),
        "T2_unavailable": t2 is None,
        "T3_unavailable": t3_time is None,
        "T4_unavailable": t4 is None,
        "T5_unavailable": t5 is None,
    }
    (directory / "latency-analysis.json").write_text(
        json.dumps({"run_id": run_id, "job_count": len(job_rows), "missing_events": missing}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Analyzed {len(job_rows)} correlated jobs in {directory}")
    print(
        f"Scale events captured: T2={'yes' if t2 else 'no'}, T3={'yes' if t3_time else 'no'}, "
        f"T4={'yes' if t4 else 'no'}, T5={'yes' if t5 else 'no'}."
    )
    print(
        "Wrote job-latencies.csv, scale-events.csv, run-latencies.csv, "
        "latency-summary.csv, latency-analysis.json."
    )
    generate_plots(directory, job_rows)


def generate_plots(directory, job_rows):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates

        # Plot 1: Replicas & SQS Queue Backlog Time-Series
        sqs_file = directory / "sqs-attributes.tsv"
        rep_file = directory / "replicas.tsv"

        sqs_times, sqs_visible = [], []
        if sqs_file.exists():
            with sqs_file.open(encoding="utf-8", errors="replace") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) >= 2:
                        t = parse_timestamp(parts[0])
                        val = int(parts[1]) if parts[1].isdigit() else None
                        if t and val is not None:
                            sqs_times.append(t)
                            sqs_visible.append(val)

        rep_times, rep_desired, rep_ready = [], [], []
        if rep_file.exists():
            with rep_file.open(encoding="utf-8", errors="replace") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) >= 3:
                        t = parse_timestamp(parts[0])
                        des = int(parts[1]) if parts[1].isdigit() else None
                        rdy = int(parts[2]) if parts[2].isdigit() else None
                        if t and des is not None and rdy is not None:
                            rep_times.append(t)
                            rep_desired.append(des)
                            rep_ready.append(rdy)

        if sqs_times or rep_times:
            fig, ax1 = plt.subplots(figsize=(11, 5.5))
            color_sqs = '#2563eb'
            ax1.set_xlabel('Time (UTC)', fontweight='bold')
            ax1.set_ylabel('SQS Backlog (Visible Messages)', color=color_sqs, fontweight='bold')
            if sqs_times:
                ax1.plot(sqs_times, sqs_visible, color=color_sqs, linewidth=2.5, label='SQS Backlog (Messages)')
            ax1.tick_params(axis='y', labelcolor=color_sqs)
            ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
            ax1.grid(True, linestyle='--', alpha=0.4)

            ax2 = ax1.twinx()
            color_rep = '#dc2626'
            ax2.set_ylabel('Worker Pods (Replicas)', color=color_rep, fontweight='bold')
            if rep_times:
                ax2.step(rep_times, rep_desired, color='#f59e0b', linestyle='--', where='post', linewidth=1.8, label='Desired Replicas (HPA)')
                ax2.step(rep_times, rep_ready, color=color_rep, where='post', linewidth=2.5, label='Ready Replicas (Worker Pods)')
            ax2.tick_params(axis='y', labelcolor=color_rep)
            max_y = max(rep_desired + rep_ready + [4]) if (rep_desired or rep_ready) else 5
            ax2.set_ylim(0, max_y + 1)

            fig.tight_layout()
            plt.title(f'KEDA Autoscaling Time-Series: SQS Backlog vs Worker Replicas\nExperiment: {directory.name}', fontsize=12, fontweight='bold')

            lines1, labels1 = ax1.get_legend_handles_labels()
            lines2, labels2 = ax2.get_legend_handles_labels()
            ax1.legend(lines1 + lines2, labels1 + labels2, loc='upper right', framealpha=0.9)

            out_png = directory / "timeseries-backlog-replicas.png"
            plt.savefig(out_png, dpi=160)
            plt.close()
            print(f"Generated chart: {out_png}")

        # Plot 2: Per-job E2E Latency Scatter & Distribution
        valid_jobs = [r for r in job_rows if r.get("client_sent_at") and r.get("e2e_latency_ms")]
        if valid_jobs:
            fig, ax = plt.subplots(figsize=(11, 4.5))
            job_times = [parse_timestamp(r["client_sent_at"]) for r in valid_jobs]
            job_latencies = [float(r["e2e_latency_ms"]) for r in valid_jobs]

            ax.scatter(job_times, job_latencies, color='#059669', alpha=0.6, s=25, edgecolors='none', label='Job E2E Latency (T6 - T0)')
            ax.set_xlabel('Job Submission Time (UTC)', fontweight='bold')
            ax.set_ylabel('End-to-End Latency (ms)', fontweight='bold')
            ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
            ax.grid(True, linestyle='--', alpha=0.4)
            plt.title(f'Per-Job End-to-End Latency Over Time\nExperiment: {directory.name}', fontsize=12, fontweight='bold')
            ax.legend(loc='upper right')

            fig.tight_layout()
            out_lat_png = directory / "job-e2e-latency.png"
            plt.savefig(out_lat_png, dpi=160)
            plt.close()
            print(f"Generated chart: {out_lat_png}")

    except Exception as e:
        print(f"Plot generation skipped or failed: {e}")


if __name__ == "__main__":
    main()
