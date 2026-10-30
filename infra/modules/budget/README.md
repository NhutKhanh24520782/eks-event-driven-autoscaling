# AWS Budget Module

Creates a monthly USD cost budget and actual-spend email notifications for
each configured threshold. The dev environment uses thresholds of 50%, 80%,
and 100%.

Budget notifications are not a hard spending cap and may arrive after charges
occur. Keep alert email addresses current and use AWS billing tools to review
actual usage.

## Follow-up work

- Add forecast notifications and budget actions where appropriate.
- Validate the email list and document subscription confirmation.
- Reconcile budget thresholds with current regional pricing and project scope.
