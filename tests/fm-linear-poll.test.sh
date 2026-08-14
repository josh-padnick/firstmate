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
    {data:{viewer:{displayName:"josh.padnickfirstmate"},
           comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}
  ' > "$dir/01-comments.json"
  jq -n --argjson nodes "$issues" '
    {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$nodes}}}
  ' > "$dir/02-issues.json"
}

comment() {  # <id> <updated> <body> <author> <issue>
  jq -nc --arg id "$1" --arg updated "$2" --arg body "$3" --arg author "$4" --arg issue "$5" '
    {id:$id,createdAt:$updated,updatedAt:$updated,body:$body,
     user:{displayName:$author},issue:{identifier:$issue},parent:null}
  '
}

history() {  # <id> <created> <actor> <from> <to>
  jq -nc --arg id "$1" --arg created "$2" --arg actor "$3" --arg from "$4" --arg to "$5" '
    {id:$id,createdAt:$created,actor:{displayName:$actor},
     fromState:{name:$from},toState:{name:$to},fromAssignee:null,toAssignee:null,
     updatedDescription:null,addedLabels:[],removedLabels:[]}
  '
}

issue() {  # <id> <updated> <creator> <history-json> [status] [assignee]
  jq -nc --arg id "$1" --arg updated "$2" --arg creator "$3" --argjson history "$4" \
    --arg status "${5:-Backlog}" --arg assignee "${6:-}" '
    {identifier:$id,title:"fixture",description:"",updatedAt:$updated,
     createdAt:"2026-08-01T00:00:00Z",state:{name:$status},
     assignee:(if $assignee == "" then null else {displayName:$assignee} end),
     creator:{displayName:$creator},labels:{nodes:[]},
     history:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$history}}
  '
}

run_poll() {  # <home> <fixtures>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_LINEAR_FIXTURE_DIR="$2" \
    FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_PENDING_ALARM_SECONDS="${FM_LINEAR_PENDING_ALARM_SECONDS:-9999}" "$POLL"
}

pending_count() {  # <home>
  find "$1/state/linear-inbox" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# T1, T5, and the author-identity half of the concurrent-write regression.
home=$(make_home idempotence)
fixtures="$TMP_ROOT/idempotence-fixtures"
self_comment=$(comment self-comment 2026-08-14T11:58:00Z own josh.padnickfirstmate BIG-1)
captain_comment=$(comment captain-comment 2026-08-14T11:58:01Z captain josh.padnick BIG-1)
self_history=$(history self-history 2026-08-14T11:58:02Z josh.padnickfirstmate Backlog Building)
captain_history=$(history captain-history 2026-08-14T11:58:03Z josh.padnick Building Backlog)
comments=$(jq -nc --argjson a "$self_comment" --argjson b "$captain_comment" '[$a,$b]')
histories=$(jq -nc --argjson a "$self_history" --argjson b "$captain_history" '[$a,$b]')
issues=$(jq -nc --argjson a "$(issue BIG-1 2026-08-14T11:58:04Z josh.padnickfirstmate "$histories")" '[$a]')
make_fixtures "$fixtures" "$comments" "$issues"
out1=$(run_poll "$home" "$fixtures") || fail "initial interleaved poll failed"
assert_contains "$out1" "2 captain input(s)" "interleaved poll did not surface exactly the captain's events"
[ "$(pending_count "$home")" = 2 ] || fail "interleaved poll did not persist exactly two captain events"
[ "$(wc -l < "$home/state/.linear-seen.tsv" | tr -d ' ')" = 4 ] || fail "self events were not retained in the seen ledger"
out2=$(run_poll "$home" "$fixtures") || fail "second identical poll failed"
[ -z "$out2" ] || fail "second identical poll was not silent: $out2"
[ "$(pending_count "$home")" = 2 ] || fail "second identical poll duplicated an inbox event"
pass "poller is idempotent and filters only by author identity"

# A write can finish after its self-events were first observed.
# Re-reading a seen self-event must still close the outbound observation loop.
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-1",target_state:"Building",comment_id:"self-comment"}' \
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
page_comment=$(comment page-one 2026-08-14T11:59:00Z captain josh.padnick BIG-2)
jq -n --argjson node "$page_comment" '
  {data:{viewer:{displayName:"josh.padnickfirstmate"},
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
page_two=$(comment page-two 2026-08-14T11:59:01Z captain josh.padnick BIG-3)
jq -n --argjson node "$page_two" '
  {data:{viewer:{displayName:"josh.padnickfirstmate"},
   comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}
' > "$fixtures/02-comments-page-two.json"
jq -n '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/03-issues.json"
run_poll "$home" "$fixtures" >/dev/null || fail "pagination retry failed"
[ "$(pending_count "$home")" = 2 ] || fail "pagination retry did not publish both events exactly once"
pass "failed pagination holds the cursor and a retry captures every page"

# T7: body hashes surface an edit but absorb a reply-only updatedAt bump.
home=$(make_home edits)
fixtures="$TMP_ROOT/edit-one"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:55:00Z first josh.padnick BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "initial edit fixture failed"
[ "$(pending_count "$home")" = 1 ] || fail "initial comment was not captured"
fixtures="$TMP_ROOT/edit-two"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:56:00Z 'first plus more' josh.padnick BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
out=$(run_poll "$home" "$fixtures") || fail "edited comment poll failed"
assert_contains "$out" "1 captain input(s)" "edited comment did not surface"
[ "$(pending_count "$home")" = 2 ] || fail "edited body did not create a new content event"
fixtures="$TMP_ROOT/edit-bump"
comments=$(jq -nc --argjson c "$(comment edit-id 2026-08-14T11:57:00Z 'first plus more' josh.padnick BIG-4)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
out=$(run_poll "$home" "$fixtures") || fail "reply-bump poll failed"
[ -z "$out" ] || fail "same-body reply bump was not silent: $out"
[ "$(pending_count "$home")" = 2 ] || fail "same-body reply bump duplicated the comment"
pass "comment edits surface and same-body reply bumps dedupe"

# T8: transport, JSON, and missing-key failures are loud and preserve cursors.
home=$(make_home failures)
printf 'comments_updated_at=2026-08-14T11:00:00Z\nissues_updated_at=2026-08-14T11:00:00Z\n' > "$home/state/.linear-cursor"
before=$(shasum "$home/state/.linear-cursor")
fixtures="$TMP_ROOT/fail-http"
mkdir -p "$fixtures"
printf '{}\n' > "$fixtures/01-fail-500.json"
run_poll "$home" "$fixtures" >/dev/null 2>&1 || true
run_poll "$home" "$fixtures" >/dev/null 2>&1 || true
out=$(run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "POLL FAILING (3x)" "third HTTP failure was not loud"
[ "$before" = "$(shasum "$home/state/.linear-cursor")" ] || fail "HTTP failures advanced the cursor"

home=$(make_home malformed)
fixtures="$TMP_ROOT/fail-malformed"
mkdir -p "$fixtures"
printf '{broken\n' > "$fixtures/01-malformed.json"
run_poll "$home" "$fixtures" >/dev/null 2>&1 || true
run_poll "$home" "$fixtures" >/dev/null 2>&1 || true
out=$(run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "POLL FAILING (3x)" "third malformed response was not loud"

home=$(make_home missing-key)
: > "$home/.env"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLL" 2>&1 || true)
assert_contains "$out" "missing LINEAR_API_KEY" "missing key failed silently"
pass "every inability to poll becomes a loud, durable failure episode"

# T9 and T11: old pending inputs and turn-marker drift announce every sweep.
home=$(make_home alarms)
fixtures="$TMP_ROOT/alarm-fixtures"
bad_issue=$(issue BIG-9 2026-08-14T11:59:00Z josh.padnickfirstmate '[]' 'Approve Deliverable' josh.padnickfirstmate)
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

# Migration contract: bootstrap arms and registers the replacement before
# removing every legacy absorb/snapshot/cursor artifact, then preserves the
# check when a previously configured key disappears so the poll can fail loud.
home=$(make_home bootstrap)
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  printf 'legacy\n' > "$home/state/$legacy"
done
out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" "LINEAR: event-ledger poll armed" "bootstrap did not arm the Linear replacement"
[ -x "$home/state/fm-linear-inbox.check.sh" ] || fail "bootstrap did not publish an executable Linear shim"
[ -f "$home/state/fm-linear-inbox.check-trust" ] || fail "bootstrap did not hash-register the Linear shim"
grep -F 'fm-linear-poll.sh' "$home/state/fm-linear-inbox.check.sh" >/dev/null \
  || fail "Linear shim does not dispatch the tracked poller"
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  [ ! -e "$home/state/$legacy" ] || fail "bootstrap left legacy state/$legacy beside the replacement"
done
grep -qx 'export FM_CHECK_INTERVAL=30' "$home/config/x-mode.env" \
  || fail "Linear activation did not install the 30-second connector cadence"
: > "$home/.env"
FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ -x "$home/state/fm-linear-inbox.check.sh" ] || fail "missing key silently disarmed an established Linear poll"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$home/state/fm-linear-inbox.check.sh" 2>&1 || true)
assert_contains "$out" "missing LINEAR_API_KEY" "established shim did not announce a missing key"
pass "bootstrap replaces legacy polling only after the event-ledger shim is registered"

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
