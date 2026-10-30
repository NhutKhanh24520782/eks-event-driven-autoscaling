# Load Test

`k6-workload.js` sends JSON `POST /jobs` requests to the configured API. It
uses `API_URL` when supplied and otherwise targets `http://localhost:8080`.
The current stages ramp to 10 virtual users, hold, ramp to 50, hold, then ramp
down. Each virtual user sleeps for one second between requests.

Run against local Compose:

```powershell
k6 run scripts\load-test\k6-workload.js
```

Run against a development ALB:

```powershell
k6 run -e API_URL=http://<DEV-ALB-HOSTNAME> scripts\load-test\k6-workload.js
```

Each successful API response means the message was accepted by SQS, not
necessarily processed. Confirm worker logs and Prometheus counters, and check
queue depth in CloudWatch. Use a development queue only; the script can create
a significant backlog and incur costs.

## Follow-up work

- Make stages, job processing time, and request rate configurable.
- Add thresholds for accepted responses, errors, latency, and dropped
  iterations.
- Provide low-load smoke and bounded test profiles.
- Add unique test-run identifiers and evidence/report output.
- Use a separate CPU stress workload for HPA tests; the worker's timer delay
  does not create meaningful CPU load.
