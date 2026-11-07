# SQS Module

Creates a main queue and a dead-letter queue. The main queue uses the configured
visibility timeout and long-poll wait time, with a redrive policy targeting
the DLQ after the configured `max_receive_count`. The DLQ retains messages
for 14 days.

Keep the visibility timeout longer than normal job processing time. The
worker currently does not extend visibility for long-running jobs.

## Follow-up work

- Add queue encryption, explicit TLS policy, and alarms for visible/old
  messages and DLQ depth.
- Validate timeout and redrive settings against worker behavior.
- Document a safe DLQ inspection and redrive process.
