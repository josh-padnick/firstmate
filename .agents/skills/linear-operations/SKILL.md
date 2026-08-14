---
name: linear-operations
description: >-
  Agent-only handling and write procedure for Firstmate's durable Linear event ledger.
  Use on any Linear check wake and before Firstmate changes a Linear issue, assignee, or comment.
user-invocable: false
metadata:
  internal: true
---

# Linear operations

Load this on every `check:` wake whose payload begins `linear:` and before Firstmate writes a Linear state, assignee, or comment.
The tracked scripts own all storage and mutation mechanics.
This skill owns the agent-side handler contract.

## Handle every pending captain event

The wake line is an announcement, not a complete event list.
Always enumerate every `state/linear-inbox/*.json` record that lacks its adjacent `.handled` marker.
Sort the records by `created_at`, oldest first, before acting.
Do not limit handling to the issue identifiers named in the wake.

Each event record is a durable pointer plus a bounded excerpt.
For a comment event, read the current Linear comment by `comment_id` before acting so content beyond the excerpt is never discarded.
For board, description, label, and issue-created events, read the named issue and reconcile the server state before acting.
An edited comment has the same `comment_id` and a different `body_sha256`; treat it as a new instruction and read the current body again.

Process an event idempotently.
Before dispatching or creating local work, reconcile whether the demanded action is already done or durably queued.
Mark the event handled only after its action is complete or durably queued.
For an event at `<uuid>.json`, create the adjacent marker privately with `umask 077; : > "<uuid>.handled"`.
An interruption before that marker deliberately causes the event to be offered again.

## Use the one outbound door

Use `bin/fm-linear-act.sh` for every state, assignee, and comment write.
Do not call `linear-axi issue update`, `issueUpdate`, or `commentCreate` directly for those writes.
The script's header and `--help`-shaped usage block own its exact subcommands.

Use `handoff-to-captain` when the board enters a captain-owned review or decision state.
Use `take-from-captain` when accepted input returns the board to a Firstmate-owned state.
Use `reply` for a comment-only response in the captain's existing thread.
Use `escalate` for a visible Firstmate or captain decision gate.
Use `resume` whenever an unfinished journal is announced.
Use `repair` whenever the poll reports a turn-marker mismatch.

The script journals the intent before mutation, derives assignee from status, changes state and assignee in one API mutation, reuses one client-generated comment ID across retries, and verifies the board by read-back.
Never edit a `state/linear-outbox` journal by hand.

## Treat loud lines as operational failures

- `POLL FAILING` means the board channel cannot currently be observed.
  Diagnose the named credential, transport, HTTP, or response failure and tell the captain in chat that the board channel is down.
- `UNHANDLED captain inputs` means the oldest pending records have exceeded the handling threshold.
  Drain all pending records immediately.
- `UNFINISHED write` means an outbound journal must be resumed.
- `WRITE NOT OBSERVED` means a verified write has not appeared in the inbound self-event loop after three sweeps.
  Re-read the issue and repair or escalate the discrepancy.
- `TURN-MARKER MISMATCH` means state and assignee disagree with the status truth table.
  Run `fm-linear-act.sh repair <BIG-n>` after confirming the current status.
- `UNKNOWN STATUS` means the closed status table cannot safely infer an assignee.
  Stop and update the table deliberately rather than guessing.
- `CURSOR ANOMALY` or `POLL STATE FAILURE` means the poller refused to advance.
  Captain input remains replayable, but the implementation or private state needs investigation.

Never suppress a Linear wake by refreshing state or running an absorb pass.
The old absorb flag, snapshot, and id-only seen file have no supported replacement because author identity and content-aware ledger keys remove the need for them.
