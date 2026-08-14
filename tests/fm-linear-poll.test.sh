#!/usr/bin/env bash
# Regression tests for the durable Linear event-ledger poller.
#
# These cases exercise the executable against ordered GraphQL fixtures and a
# scratch FM_HOME.
# They pin idempotence, rewind, pagination failure, author identity, unordered
# records, comment edits, loud failures, stale pending events, and board audits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-linear-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear-poll)
NOW=$(jq -nr '"2026-08-14T12:00:00Z" | fromdateiso8601')

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf 'LINEAR_API_KEY=test-key\n' > "$home/.env"
  chmod 0600 "$home/.env"
  printf '%s\n' "$home"
}

make_fixtures() {  # <dir> <comments-json> <issues-json>
  local dir=$1 comments=$2 issues=$3
  mkdir -p "$dir"
  jq -n --argjson nodes "$comments" '
    {data:{viewer:{id:"firstmate-id",displayName:"shared-name"},
           comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}
  ' > "$dir/01-comments.json"
  jq -n --argjson nodes "$issues" '
    {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}
  ' > "$dir/02-issues.json"
}

comment() {  # <id> <updated> <body> <author-id> <author-name> <issue>
  jq -nc --arg id "$1" --arg updated "$2" --arg body "$3" --arg author_id "$4" --arg author "$5" --arg issue "$6" '
    {id:$id,createdAt:$updated,updatedAt:$updated,body:$body,
     user:{id:$author_id,displayName:$author},issue:{identifier:$issue},parent:null}
  '
}

history() {  # <id> <created> <actor-id> <actor-name> <from> <to> [to-assignee-id] [to-assignee-name]
  jq -nc --arg id "$1" --arg created "$2" --arg actor_id "$3" --arg actor "$4" --arg from "$5" --arg to "$6" \
    --arg to_assignee_id "${7:-}" --arg to_assignee "${8:-}" '
    {id:$id,createdAt:$created,actor:{id:$actor_id,displayName:$actor},
     fromState:{name:$from},toState:{name:$to},fromAssignee:null,
     toAssignee:(if $to_assignee_id == "" then null else {id:$to_assignee_id,displayName:$to_assignee} end),
     updatedDescription:null,addedLabels:[],removedLabels:[]}
  '
}

issue() {  # <id> <updated> <creator-id> <creator-name> <history-json> [status] [assignee-id] [assignee-name] [description]
  jq -nc --arg id "$1" --arg updated "$2" --arg creator_id "$3" --arg creator "$4" --argjson history "$5" \
    --arg status "${6:-Backlog}" --arg assignee_id "${7:-}" --arg assignee "${8:-}" \
    --arg description "${9:-}" '
    {identifier:$id,title:"fixture",description:$description,updatedAt:$updated,
     createdAt:"2026-08-01T00:00:00Z",state:{name:$status},
     assignee:(if $assignee_id == "" then null else {id:$assignee_id,displayName:$assignee} end),
     creator:{id:$creator_id,displayName:$creator},labels:{nodes:[]},
     history:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$history}}
  '
}

run_poll() {  # <home> <fixtures>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_LINEAR_FIXTURE_DIR="$2" \
    FM_LINEAR_FIXTURE_LOG="${FM_LINEAR_FIXTURE_LOG:-}" \
    FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_PENDING_ALARM_SECONDS="${FM_LINEAR_PENDING_ALARM_SECONDS:-9999}" "$POLL"
}

pending_count() {  # <home>
  find "$1/state/linear-inbox" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# T1, T5, and the author-identity half of the concurrent-write regression.
home=$(make_home idempotence)
fixtures="$TMP_ROOT/idempotence-fixtures"
request_log="$home/request.log"
self_comment=$(comment self-comment 2026-08-14T11:58:00Z own firstmate-id shared-name BIG-1)
captain_comment=$(comment captain-comment 2026-08-14T11:58:01Z captain captain-id shared-name BIG-1)
self_history=$(history self-history 2026-08-14T11:58:02Z firstmate-id shared-name Backlog Building firstmate-id shared-name)
captain_history=$(history captain-history 2026-08-14T11:58:03Z captain-id shared-name Building Backlog)
comments=$(jq -nc --argjson a "$self_comment" --argjson b "$captain_comment" '[$a,$b]')
histories=$(jq -nc --argjson a "$self_history" --argjson b "$captain_history" '[$a,$b]')
issues=$(jq -nc --argjson a "$(issue BIG-1 2026-08-14T11:58:04Z firstmate-id shared-name "$histories")" '[$a]')
make_fixtures "$fixtures" "$comments" "$issues"
out1=$(FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures") || fail "initial interleaved poll failed"
assert_contains "$out1" "2 captain input(s)" "interleaved poll did not surface exactly the captain's events"
[ "$(pending_count "$home")" = 2 ] || fail "interleaved poll did not persist exactly two captain events"
[ "$(wc -l < "$home/state/.linear-seen.tsv" | tr -d ' ')" = 2 ] || fail "self history was not retained in the seen ledger"
[ "$(wc -l < "$home/state/.linear-comment-heads.tsv" | tr -d ' ')" = 2 ] || fail "latest hashes were not retained for both comments"
out2=$(FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures") || fail "second identical poll failed"
[ -z "$out2" ] || fail "second identical poll was not silent: $out2"
[ "$(pending_count "$home")" = 2 ] || fail "second identical poll duplicated an inbox event"
awk -F '\t' '$1 == "comments" { print $2 }' "$request_log" \
  | jq -s -e 'length == 2 and all(.[];
      .variables.team == "BIG"
      and (.query | contains("issue:{team:{key:{eq:$team}}}")))' >/dev/null \
  || fail "comment request protocol did not scope both cursor modes to BIG"
pass "poller is idempotent and filters only by author identity"

captured=$(find "$home/state/linear-inbox" -type f -name '*.json' -exec jq -r 'select(.comment_id == "captain-comment") | .author_id' {} +)
[ "$captured" = captain-id ] || fail "captain comment with the viewer's display name was misclassified"
pass "stable user IDs distinguish authors with the same display name"

# A write can finish after its self-events were first observed.
# Re-reading a seen self-event must still close the outbound observation loop.
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-1",target_state:"Building",assignee_id:"firstmate-id",comment_id:"self-comment"}' \
  > "$home/state/linear-outbox/late-journal.done"
chmod 0700 "$home/state/linear-outbox"
chmod 0600 "$home/state/linear-outbox/late-journal.done"
out=$(run_poll "$home" "$fixtures") || fail "seen self-event reconciliation failed"
[ -z "$out" ] || fail "seen self-event reconciliation printed output: $out"
[ -f "$home/state/linear-outbox/late-journal.comment-observed" ] \
  || fail "seen self-comment did not close the outbound observation loop"
[ -f "$home/state/linear-outbox/late-journal.board-observed" ] \
  || fail "seen self-board event did not close the outbound observation loop"
pass "seen self-events still reconcile a journal that completed after their first poll"

# T2 and T6: a rewind re-reads shuffled records and restores the true maximum.
printf 'comments_updated_at=2026-08-14T10:00:00Z\nissues_updated_at=2026-08-14T10:00:00Z\n' > "$home/state/.linear-cursor"
out=$(run_poll "$home" "$fixtures") || fail "rewound poll failed"
[ -z "$out" ] || fail "rewound duplicate poll was not silent: $out"
grep -qx 'comments_updated_at=2026-08-14T11:58:01Z' "$home/state/.linear-cursor" \
  || fail "rewind did not restore the maximum comment timestamp"
grep -qx 'issues_updated_at=2026-08-14T11:58:04Z' "$home/state/.linear-cursor" \
  || fail "rewind did not restore the maximum issue timestamp"
pass "rewound cursors safely re-read and restore observed maxima"

# T3: empty responses never move a cursor.
home=$(make_home empty)
printf 'comments_updated_at=2026-08-14T11:00:00Z\nissues_updated_at=2026-08-14T11:00:00Z\n' > "$home/state/.linear-cursor"
before=$(shasum "$home/state/.linear-cursor")
fixtures="$TMP_ROOT/empty-fixtures"
make_fixtures "$fixtures" '[]' '[]'
out=$(run_poll "$home" "$fixtures") || fail "empty poll failed"
[ -z "$out" ] || fail "empty poll printed output: $out"
[ "$before" = "$(shasum "$home/state/.linear-cursor")" ] || fail "empty poll changed the cursor"
pass "empty results leave both cursors byte-identical"

# T4: a failure on page two cannot advance or partially publish.
home=$(make_home pagination)
printf 'comments_updated_at=2026-08-14T11:00:00Z\nissues_updated_at=2026-08-14T11:00:00Z\n' > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/pagination-fail"
mkdir -p "$fixtures"
page_comment=$(comment page-one 2026-08-14T11:59:00Z captain captain-id shared-name BIG-2)
jq -n --argjson node "$page_comment" '
  {data:{viewer:{id:"firstmate-id",displayName:"shared-name"},
   comments:{pageInfo:{hasNextPage:true,endCursor:"next"},nodes:[$node]}}}
' > "$fixtures/01-comments-page-one.json"
printf '{}\n' > "$fixtures/02-fail-500.json"
before=$(shasum "$home/state/.linear-cursor")
run_poll "$home" "$fixtures" >/dev/null 2>&1 && fail "page-two HTTP failure unexpectedly succeeded"
[ "$before" = "$(shasum "$home/state/.linear-cursor")" ] || fail "page-two failure advanced the cursor"
[ "$(pending_count "$home")" = 0 ] || fail "page-two failure published a partial inbox"

fixtures="$TMP_ROOT/pagination-good"
mkdir -p "$fixtures"
cp "$TMP_ROOT/pagination-fail/01-comments-page-one.json" "$fixtures/01-comments-page-one.json"
page_two=$(comment page-two 2026-08-14T11:59:01Z captain captain-id shared-name BIG-3)
jq -n --argjson node "$page_two" '
  {data:{viewer:{id:"firstmate-id",displayName:"shared-name"},
   comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}
' > "$fixtures/02-comments-page-two.json"
jq -n '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/03-issues.json"
run_poll "$home" "$fixtures" >/dev/null || fail "pagination retry failed"
[ "$(pending_count "$home")" = 2 ] || fail "pagination retry did not publish both events exactly once"
pass "failed pagination holds the cursor and a retry captures every page"

# T7: body hashes surface an edit but absorb a reply-only updatedAt bump.
home=$(make_home edits)
fixtures="$TMP_ROOT/edit-one"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:55:00Z first captain-id shared-name BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "initial edit fixture failed"
[ "$(pending_count "$home")" = 1 ] || fail "initial comment was not captured"
fixtures="$TMP_ROOT/edit-two"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:56:00Z 'first plus more' captain-id shared-name BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
out=$(run_poll "$home" "$fixtures") || fail "edited comment poll failed"
assert_contains "$out" "1 captain input(s)" "edited comment did not surface"
[ "$(pending_count "$home")" = 2 ] || fail "edited body did not create a new content event"
fixtures="$TMP_ROOT/edit-bump"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:57:00Z 'first plus more' captain-id shared-name BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
out=$(run_poll "$home" "$fixtures") || fail "reply-bump poll failed"
[ -z "$out" ] || fail "same-body reply bump was not silent: $out"
[ "$(pending_count "$home")" = 2 ] || fail "same-body reply bump duplicated the comment"
fixtures="$TMP_ROOT/edit-revert"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:58:00Z first captain-id shared-name BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
out=$(run_poll "$home" "$fixtures") || fail "reverted comment poll failed"
assert_contains "$out" "1 captain input(s)" "A-to-B-to-A edit did not surface the final A"
[ "$(pending_count "$home")" = 3 ] || fail "A-to-B-to-A did not persist three comment transitions"
pass "comment transitions surface A-to-B-to-A and silence same-body bumps"

home=$(make_home retained-head)
fixtures="$TMP_ROOT/retained-head-old-fixtures"
comments=$(jq -nc --argjson c "$(comment retained-head-id 2026-07-01T00:00:00Z unchanged captain-id shared-name BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "old comment-head seed poll failed"
[ "$(wc -l < "$home/state/.linear-comment-heads.tsv" | tr -d ' ')" = 1 ] \
  || fail "latest comment head expired with retained event state"
fixtures="$TMP_ROOT/retained-head-bump-fixtures"
comments=$(jq -nc --argjson c "$(comment retained-head-id 2026-08-14T11:58:00Z unchanged captain-id shared-name BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
out=$(run_poll "$home" "$fixtures") || fail "old unchanged parent bump poll failed"
[ -z "$out" ] || fail "old unchanged parent bump resurfaced captain input: $out"
[ "$(pending_count "$home")" = 0 ] || fail "old unchanged parent bump created a durable duplicate"
pass "latest comment heads outlive event retention and silence old bumps"

home=$(make_home complete-body)
long_body=$(printf 'captain-%0500d' 7)
fixtures="$TMP_ROOT/complete-body-fixtures"
comments=$(jq -nc --argjson c "$(comment long-comment 2026-08-14T11:58:00Z "$long_body" captain-id shared-name BIG-5)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "long captain comment poll failed"
body_file=$(find "$home/state/linear-inbox" -type f -name '*.json' | head -n 1)
[ "$(jq -r '.body' "$body_file")" = "$long_body" ] || fail "durable inbox truncated the observed captain comment"
pass "the durable inbox preserves the complete observed comment body"

home=$(make_home complete-description)
fixtures="$TMP_ROOT/complete-description-fixtures"
description=$(printf 'captain-description-%0500d' 8)
description_history=$(history description-edit 2026-08-14T11:58:00Z captain-id shared-name Backlog Backlog)
description_history=$(printf '%s' "$description_history" | jq '
  .fromState = null | .toState = null | .updatedDescription = true
')
histories=$(jq -nc --argjson h "$description_history" '[$h]')
edited_issue=$(issue BIG-6 2026-08-14T11:58:01Z captain-id shared-name "$histories" Backlog '' '' "$description")
created_issue=$(issue BIG-7 2026-08-14T11:59:01Z captain-id shared-name '[]' Backlog '' '' "firstmate $description")
created_issue=$(printf '%s' "$created_issue" | jq '.createdAt = "2026-08-14T11:59:00Z"')
issues=$(jq -nc --argjson a "$edited_issue" --argjson b "$created_issue" '[$a,$b]')
make_fixtures "$fixtures" '[]' "$issues"
run_poll "$home" "$fixtures" >/dev/null || fail "complete description poll failed"
jq -s -e --arg description "$description" '
  any(.[]; .kind == "description" and .description == $description)
' "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "description edit omitted the complete observed description"
jq -s -e --arg description "firstmate $description" '
  any(.[]; .kind == "issue-created" and .description == $description)
' "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "issue creation omitted the complete observed description"
pass "the durable inbox preserves complete observed issue descriptions"

# T8: transport, JSON, and missing-key failures are loud and preserve cursors.
home=$(make_home failures)
printf 'comments_updated_at=2026-08-14T11:00:00Z\nissues_updated_at=2026-08-14T11:00:00Z\n' > "$home/state/.linear-cursor"
before=$(shasum "$home/state/.linear-cursor")
fixtures="$TMP_ROOT/fail-http"
mkdir -p "$fixtures"
printf '{}\n' > "$fixtures/01-fail-500.json"
out=$(run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "POLL FAILING (1x)" "first HTTP failure was not loud"
[ "$before" = "$(shasum "$home/state/.linear-cursor")" ] || fail "HTTP failures advanced the cursor"

home=$(make_home malformed)
fixtures="$TMP_ROOT/fail-malformed"
mkdir -p "$fixtures"
printf '{broken\n' > "$fixtures/01-malformed.json"
out=$(run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "POLL FAILING (1x)" "first malformed response was not loud"

home=$(make_home missing-key)
: > "$home/.env"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLL" 2>&1 || true)
assert_contains "$out" "missing LINEAR_API_KEY" "missing key failed silently"
pass "every inability to poll becomes a loud, durable failure episode"

# T9 and T11: old pending inputs and turn-marker drift announce every sweep.
home=$(make_home alarms)
fixtures="$TMP_ROOT/alarm-fixtures"
bad_issue=$(issue BIG-9 2026-08-14T11:59:00Z firstmate-id shared-name '[]' 'Approve Deliverable' firstmate-id shared-name)
issues=$(jq -nc --argjson i "$bad_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
mkdir -p "$home/state/linear-inbox"
jq -n '{kind:"comment",issue:"BIG-8",created_at:"2026-08-14T11:40:00Z"}' \
  > "$home/state/linear-inbox/stale.json"
chmod 0700 "$home/state/linear-inbox"
chmod 0600 "$home/state/linear-inbox/stale.json"
out=$(FM_LINEAR_PENDING_ALARM_SECONDS=300 run_poll "$home" "$fixtures") || fail "alarm poll failed"
assert_contains "$out" "UNHANDLED captain inputs" "stale pending event was silent"
assert_contains "$out" "TURN-MARKER MISMATCH BIG-9" "board invariant mismatch was silent"
pass "stale pending events and turn-marker drift wake loudly"

home=$(make_home unknown-status)
fixtures="$TMP_ROOT/unknown-status-fixtures"
unknown_issue=$(issue BIG-10 2026-08-14T11:59:00Z captain-id shared-name '[]' QA)
issues=$(jq -nc --argjson i "$unknown_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "first unknown-status poll failed"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-10)" "first unknown-status occurrence was silent"
fixtures="$TMP_ROOT/unknown-status-empty-fixtures"
make_fixtures "$fixtures" '[]' '[]'
out=$(run_poll "$home" "$fixtures") || fail "repeated unknown-status poll failed"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-10)" "unresolved unknown status did not stay loud when absent from the incremental page"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLL" acknowledge-unknown-status BIG-10 QA) \
  || fail "unknown-status acknowledgment failed"
assert_contains "$out" "acknowledged unknown status QA (BIG-10)" "acknowledgment was not observable"
out=$(run_poll "$home" "$fixtures") || fail "acknowledged unknown-status poll failed"
assert_not_contains "$out" "UNKNOWN STATUS" "exact issue-status acknowledgment did not silence the occurrence"
fixtures="$TMP_ROOT/issue-scoped-unknown-fixtures"
unknown_issue=$(issue BIG-10 2026-08-14T12:00:00Z captain-id shared-name '[]' QA)
other_unknown_issue=$(issue BIG-11 2026-08-14T12:00:01Z captain-id shared-name '[]' QA)
issues=$(jq -nc --argjson a "$unknown_issue" --argjson b "$other_unknown_issue" '[$a,$b]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "issue-scoped unknown-status poll failed"
assert_not_contains "$out" "UNKNOWN STATUS QA (BIG-10)" "BIG-11 invalidated BIG-10's exact acknowledgment"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-11)" "BIG-10's acknowledgment silenced BIG-11"
fixtures="$TMP_ROOT/unknown-status-direct-reentry-fixtures"
left_qa=$(history left-qa 2026-08-14T12:00:10Z captain-id shared-name QA Backlog)
reentered_qa=$(history reentered-qa 2026-08-14T12:00:11Z captain-id shared-name Backlog QA)
histories=$(jq -nc --argjson a "$left_qa" --argjson b "$reentered_qa" '[$a,$b]')
unknown_issue=$(issue BIG-10 2026-08-14T12:00:12Z captain-id shared-name "$histories" QA)
issues=$(jq -nc --argjson i "$unknown_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "direct unknown-status reentry poll failed"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-10)" \
  "acknowledgment survived a leave-and-reenter sequence between polls"
fixtures="$TMP_ROOT/known-status-fixtures"
known_issue=$(issue BIG-10 2026-08-14T12:00:20Z captain-id shared-name '[]' Backlog)
other_known_issue=$(issue BIG-11 2026-08-14T12:00:21Z captain-id shared-name '[]' Backlog)
issues=$(jq -nc --argjson a "$known_issue" --argjson b "$other_known_issue" '[$a,$b]')
make_fixtures "$fixtures" '[]' "$issues"
run_poll "$home" "$fixtures" >/dev/null || fail "known-status transition poll failed"
fixtures="$TMP_ROOT/unknown-status-return-fixtures"
unknown_issue=$(issue BIG-10 2026-08-14T12:00:30Z captain-id shared-name '[]' QA)
issues=$(jq -nc --argjson i "$unknown_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "returned unknown-status poll failed"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-10)" "acknowledgment survived after the issue left its status"
pass "unknown statuses stay loud with issue-scoped expiring acknowledgments"

# Migration contract: credentials stage the replacement without cutover, and a
# separate captain-reviewed activation record permits bootstrap to arm it.
home=$(make_home bootstrap)
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  printf 'legacy\n' > "$home/state/$legacy"
done
out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_not_contains "$out" "LINEAR:" "credentials alone emitted a cutover result"
[ ! -e "$home/state/fm-linear-inbox.check.sh" ] || fail "credentials alone armed the replacement poll"
[ ! -e "$home/config/x-mode.env" ] || fail "credentials alone changed the watcher cadence"
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  [ -e "$home/state/$legacy" ] || fail "credentials alone removed legacy state/$legacy"
done
mkdir -p "$home/config"
printf 'approved\n' > "$home/config/linear-event-ledger-activation"
out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" "LINEAR: event-ledger poll armed" "bootstrap did not arm the Linear replacement"
[ -x "$home/state/fm-linear-inbox.check.sh" ] || fail "bootstrap did not publish an executable Linear shim"
[ -f "$home/state/fm-linear-inbox.check-trust" ] || fail "bootstrap did not hash-register the Linear shim"
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  [ ! -e "$home/state/$legacy" ] || fail "bootstrap left legacy state/$legacy beside the replacement"
done
interval=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
  . "$1/config/x-mode.env"
  . "$2/bin/fm-watch.sh"
  printf "%s\n" "$CHECK_INTERVAL"
' _ "$home" "$ROOT")
[ "$interval" = 30 ] || fail "the watcher did not consume the activated 30-second cadence"
: > "$home/.env"
FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ -x "$home/state/fm-linear-inbox.check.sh" ] || fail "missing key silently disarmed an established Linear poll"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
  . "$1/bin/fm-watch.sh"
  fm_custom_check_snapshot_prepare "$2" fm-linear-inbox || exit 1
  run_check "$FM_CUSTOM_CHECK_SNAPSHOT"
  fm_custom_check_snapshot_cleanup
' _ "$ROOT" "$home/state" 2>&1 || true)
assert_contains "$out" "missing LINEAR_API_KEY" "established shim did not announce a missing key"
printf 'LINEAR_API_KEY=test-key\n' > "$home/.env"
rm -f "$home/config/linear-event-ledger-activation"
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  printf 'legacy\n' > "$home/state/$legacy"
done
out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" "unapproved event-ledger poll disarmed" \
  "bootstrap did not report disarming a pre-existing unapproved replacement"
[ ! -e "$home/state/fm-linear-inbox.check.sh" ] || fail "pre-existing shim bypassed captain approval"
[ ! -e "$home/state/fm-linear-inbox.check-trust" ] || fail "pre-existing shim retained watcher trust without approval"
[ ! -e "$home/config/x-mode.env" ] || fail "unapproved replacement retained the 30-second cadence"
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  [ -e "$home/state/$legacy" ] || fail "unapproved replacement removed legacy state/$legacy"
done
pass "captain approval is required for pre-existing replacement artifacts"

printf 'approved\n' > "$home/config/linear-event-ledger-activation"
FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
fake_bin="$TMP_ROOT/slow-linear-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
sleep 3
exit 7
SH
chmod +x "$fake_bin/curl"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CHECK_TIMEOUT=5 \
  FM_LINEAR_POLL_DEADLINE_SECONDS=1 PATH="$fake_bin:$PATH" bash -c '
  . "$1/bin/fm-watch.sh"
  fm_custom_check_snapshot_prepare "$2" fm-linear-inbox || exit 1
  run_check "$FM_CUSTOM_CHECK_SNAPSHOT"
  fm_custom_check_snapshot_cleanup
' _ "$ROOT" "$home/state" 2>&1 || true)
assert_contains "$out" "complete poll exceeded 1s deadline" \
  "registered poll timeout was discarded by the watcher"
pass "registered Linear polls fail loudly before the watcher deadline"

# A hard kill must not make the lock a permanent silent outage.
home=$(make_home stale-lock)
mkdir -p "$home/state/.linear-poll-lock"
printf '99999999\n' > "$home/state/.linear-poll-lock/pid"
fixtures="$TMP_ROOT/stale-lock-fixtures"
make_fixtures "$fixtures" '[]' '[]'
out=$(run_poll "$home" "$fixtures") || fail "poller did not recover a stale lock owner"
[ -z "$out" ] || fail "stale-lock recovery printed a false wake: $out"
[ ! -e "$home/state/.linear-poll-lock" ] || fail "poller left its lock after stale-lock recovery"
pass "poller recovers a stale lock left by a killed process"
