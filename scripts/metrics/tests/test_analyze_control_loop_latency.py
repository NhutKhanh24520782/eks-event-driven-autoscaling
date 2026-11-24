import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ANALYZER = Path(__file__).parents[1] / "analyze-control-loop-latency.py"


class AnalyzeControlLoopLatencyTests(unittest.TestCase):
    def test_job_marks_and_scale_events_use_captured_timestamps(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            evidence = Path(temp_dir)
            (evidence / "run.txt").write_text(
                "run_id=run-1\nstarted_at=2026-11-23T15:06:00Z\n",
                encoding="utf-8",
            )
            (evidence / "run-events.csv").write_text(
                "mark,timestamp,source,uncertainty_ms\n",
                encoding="utf-8",
            )
            (evidence / "api.log").write_text(
                "[SQS SENT] job_id=run-1-job-1 client_sent_at=2026-11-23T15:06:26.000Z "
                "client_to_api_ms=200 api_received_at=2026-11-23T15:06:26.200Z "
                "enqueued_at=2026-11-23T15:06:26.300Z\n"
                "[SQS SENT] job_id=run-1-job-2 client_sent_at=2026-11-23T15:06:26.400Z "
                "client_to_api_ms=-100 api_received_at=2026-11-23T15:06:26.300Z "
                "enqueued_at=2026-11-23T15:06:26.500Z\n",
                encoding="utf-8",
            )
            (evidence / "worker.log").write_text(
                "[WORKER worker-1] [JOB START] job_id=run-1-job-1 "
                "client_sent_at=2026-11-23T15:06:26.000Z "
                "timestamp=2026-11-23T15:06:27.500Z\n"
                "[WORKER worker-1] [JOB SUCCESS] job_id=run-1-job-1 duration_ms=1000 "
                "completed_at=2026-11-23T15:06:28.500Z\n",
                encoding="utf-8",
            )
            (evidence / "replicas.tsv").write_text(
                "observed_at_utc\tdesired_replicas\tready_replicas\tavailable_replicas\n"
                "2026-11-23T15:06:00Z\t1\t1\t1\n"
                "2026-11-23T15:06:50Z\t4\t2\t2\n",
                encoding="utf-8",
            )
            (evidence / "worker-pods-before.json").write_text(
                json.dumps({"items": [{"metadata": {"name": "worker-old"}}]}),
                encoding="utf-8",
            )
            (evidence / "worker-pods.json").write_text(
                json.dumps({
                    "items": [{
                        "metadata": {
                            "name": "worker-new",
                            "labels": {"app": "worker-service"},
                            "creationTimestamp": "2026-11-23T15:06:41Z",
                        },
                        "spec": {"nodeName": "node-a"},
                        "status": {"conditions": [{
                            "type": "Ready",
                            "status": "True",
                            "lastTransitionTime": "2026-11-23T15:06:45Z",
                        }]},
                    }]
                }),
                encoding="utf-8",
            )
            hpa_event = {
                "metadata": {
                    "uid": "hpa-event-1",
                    "creationTimestamp": "2026-11-23T15:06:40Z",
                },
                "eventTime": "2026-11-23T15:06:40Z",
                "reason": "SuccessfulRescale",
                "message": "New size: 4; reason: external metric",
                "involvedObject": {
                    "kind": "HorizontalPodAutoscaler",
                    "name": "keda-hpa-worker-scaledobject",
                },
            }
            (evidence / "kubernetes-events.jsonl").write_text(
                json.dumps({
                    "observed_at_utc": "2026-11-23T15:06:40Z",
                    "event": hpa_event,
                }) + "\n" + json.dumps({
                    "items": [hpa_event],
                }) + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(ANALYZER), str(evidence)],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            with (evidence / "job-latencies.csv").open(newline="", encoding="utf-8") as file:
                jobs = {row["job_id"]: row for row in csv.DictReader(file)}
            self.assertEqual(jobs["run-1-job-1"]["client_sent_at"], "2026-11-23T15:06:26.000Z")
            self.assertEqual(jobs["run-1-job-1"]["api_received_at"], "2026-11-23T15:06:26.200Z")
            self.assertEqual(jobs["run-1-job-1"]["t1_minus_t0_ms"], "300.0")
            self.assertEqual(jobs["run-1-job-1"]["e2e_latency_ms"], "2500.0")
            self.assertEqual(jobs["run-1-job-2"]["client_to_api_ms"], "-100.0")

            with (evidence / "scale-events.csv").open(newline="", encoding="utf-8") as file:
                scale_events = list(csv.DictReader(file))
            self.assertEqual([row["mark"] for row in scale_events], ["T2", "T3", "T4", "T5"])
            self.assertEqual(scale_events[0]["timestamp_utc"], "")
            self.assertEqual(scale_events[0]["evidence_status"], "unavailable")
            self.assertEqual(scale_events[1]["timestamp_utc"], "2026-11-23T15:06:40.000Z")
            self.assertEqual(scale_events[2]["timestamp_utc"], "2026-11-23T15:06:41.000Z")
            self.assertEqual(scale_events[3]["timestamp_utc"], "2026-11-23T15:06:45.000Z")

            analysis = json.loads((evidence / "latency-analysis.json").read_text(encoding="utf-8"))
            self.assertEqual(analysis["missing_events"]["jobs_with_negative_client_to_api_ms"], 1)
            self.assertTrue(analysis["missing_events"]["T2_unavailable"])


if __name__ == "__main__":
    unittest.main()
