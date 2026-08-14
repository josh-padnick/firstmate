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
NOW=1786708800

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf 'LINEAR_API_KEY=test-key\nLINEAR_FIRSTMATE_ID=firstmate-id\nLINEAR_CAPTAIN_ID=captain-id\n' \
    > "$home/.env"
  printf '{"after":null,"complete":true}\n' > "$home/state/.linear-comment-head-bootstrap.json"
  chmod 0600 "$home/.env"
  chmod 0600 "$home/state/.linear-comment-head-bootstrap.json"
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
    {id:$id,createdAt:$updated,updatedAt:$updated,editedAt:null,body:$body,
     user:{id:$author_id,displayName:$author},
     issue:{identifier:$issue,labels:{nodes:[{name:"Firstmate"}]}},parent:null}
  '
}

history() {  # <id> <created> <actor-id> <actor-name> <from> <to> [to-assignee-id] [to-assignee-name]
  jq -nc --arg id "$1" --arg created "$2" --arg actor_id "$3" --arg actor "$4" --arg from "$5" --arg to "$6" \
    --arg to_assignee_id "${7:-}" --arg to_assignee "${8:-}" '
    {id:$id,createdAt:$created,updatedAt:$created,changes:null,actor:{id:$actor_id,displayName:$actor},
     fromState:{name:$from},toState:{name:$to},fromAssignee:null,
     toAssignee:(if $to_assignee_id == "" then null else {id:$to_assignee_id,displayName:$to_assignee} end),
     updatedDescription:null,addedLabels:[],removedLabels:[]}
  '
}

issue() {  # <id> <updated> <creator-id> <creator-name> <history-json> [status] [assignee-id] [assignee-name] [description]
  jq -nc --arg id "$1" --arg updated "$2" --arg creator_id "$3" --arg creator "$4" --argjson history "$5" \
    --arg status "${6:-Backlog}" --arg assignee_id "${7:-}" --arg assignee "${8:-}" \
    --arg description "${9:-}" '
    {identifier:$id,title:"fixture",description:$description,priority:0,dueDate:null,
     project:null,parent:null,updatedAt:$updated,
     createdAt:"2026-08-01T00:00:00Z",state:{name:$status},
     assignee:(if $assignee_id == "" then null else {id:$assignee_id,displayName:$assignee} end),
     creator:{id:$creator_id,displayName:$creator},labels:{nodes:[{name:"Firstmate"}]},
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

legacy_fixture="$ROOT/tests/fixtures/legacy-linear-inbox.check.sh.txt"
[ ! -x "$legacy_fixture" ] || fail "legacy Linear poller reference fixture is executable"
[ "$(wc -l < "$legacy_fixture" | tr -d ' ')" = 79 ] || fail "legacy Linear poller reference line count drifted"
[ "$(shasum -a 256 "$legacy_fixture" | awk '{print $1}')" = 74b764c237344bb22f0e7b0d95f076ca28c33e6064b10e1ad64cecb1975e5a32 ] \
  || fail "legacy Linear poller reference bytes drifted"
pass "legacy Linear poller remains an exact non-runtime reference"

# T1, T5, and the author-identity half of the concurrent-write regression.
home=$(make_home idempotence)
fixtures="$TMP_ROOT/idempotence-fixtures"
request_log="$home/request.log"
self_comment=$(comment self-comment 2026-08-14T11:58:00Z own firstmate-id shared-name BIG-1)
captain_comment=$(comment captain-comment 2026-08-14T11:58:01Z captain captain-id shared-name BIG-1)
self_history=$(history self-history 2026-08-14T11:58:02Z firstmate-id shared-name Backlog Building firstmate-id shared-name)
self_history=$(printf '%s' "$self_history" | jq '.fromState.id="backlog-id" | .toState.id="building-id"')
captain_history=$(history captain-history 2026-08-14T11:58:03Z captain-id shared-name Building Backlog)
comments=$(jq -nc --argjson a "$self_comment" --argjson b "$captain_comment" '[$a,$b]')
histories=$(jq -nc --argjson a "$self_history" --argjson b "$captain_history" '[$a,$b]')
issues=$(jq -nc --argjson a "$(issue BIG-1 2026-08-14T11:58:04Z firstmate-id shared-name "$histories")" '[$a]')
make_fixtures "$fixtures" "$comments" "$issues"
out1=$(FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures") || fail "initial interleaved poll failed"
assert_contains "$out1" "2 captain input(s)" "interleaved poll did not surface exactly the captain's events"
[ "$(pending_count "$home")" = 2 ] || fail "interleaved poll did not persist exactly two captain events"
[ "$(wc -l < "$home/state/.linear-history-heads.tsv" | tr -d ' ')" = 2 ] || fail "history content heads were not retained"
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

idempotence_home=$home
idempotence_fixtures=$fixtures
home=$(make_home noncaptain-authority)
fixtures="$TMP_ROOT/noncaptain-authority-fixtures"
other_comment=$(comment other-comment 2026-08-14T11:58:00Z 'not the captain' other-id shared-name BIG-30)
other_history=$(history other-history 2026-08-14T11:58:01Z other-id shared-name Backlog Building)
comments=$(jq -nc --argjson c "$other_comment" '[$c]')
other_issue=$(issue BIG-30 2026-08-14T11:58:02Z other-id shared-name "$(jq -nc --argjson h "$other_history" '[$h]')")
other_issue=$(printf '%s' "$other_issue" | jq '.createdAt="2026-08-14T11:58:02Z"')
issues=$(jq -nc --argjson i "$other_issue" '[$i]')
make_fixtures "$fixtures" "$comments" "$issues"
out=$(run_poll "$home" "$fixtures") || fail "non-captain authority poll failed"
assert_not_contains "$out" "captain input(s)" "non-captain provider IDs were promoted to captain authority"
assert_contains "$out" "3 non-authoritative observation(s)" "non-captain observations were not surfaced distinctly"
jq -s -e 'length == 3 and all(.[]; .authority == "non-captain")' \
  "$home/state/linear-inbox"/*.json >/dev/null || fail "non-captain durable events lacked explicit authority"
pass "only the canonical captain provider ID creates captain input"
home=$idempotence_home
fixtures=$idempotence_fixtures

# A write can finish after its self-events were first observed.
# Re-reading a seen self-event must still close the outbound observation loop.
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-1",target_state:"Building",state_id:"building-id",
  assignee_id:"firstmate-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:58:02Z",comment_id:"self-comment"}' \
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

home=$(make_home observation-marker-symlinks)
fixtures="$TMP_ROOT/observation-marker-symlink-fixtures"
self_comment=$(comment marker-self-comment 2026-08-14T11:58:00Z own firstmate-id shared-name BIG-44)
self_history=$(history marker-self-history 2026-08-14T11:58:01Z firstmate-id shared-name Backlog Building \
  firstmate-id shared-name)
self_history=$(printf '%s' "$self_history" | jq '.fromState.id="backlog-id" | .toState.id="building-id"')
comments=$(jq -nc --argjson c "$self_comment" '[$c]')
marker_issue=$(issue BIG-44 2026-08-14T11:58:02Z firstmate-id shared-name \
  "$(jq -nc --argjson h "$self_history" '[$h]')" Building firstmate-id shared-name)
marker_issue=$(printf '%s' "$marker_issue" | jq '.state.id="building-id"')
issues=$(jq -nc --argjson i "$marker_issue" '[$i]')
make_fixtures "$fixtures" "$comments" "$issues"
run_poll "$home" "$fixtures" >/dev/null || fail "observation marker baseline poll failed"
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-44",target_state:"Building",state_id:"building-id",
  assignee_id:"firstmate-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:58:01Z",comment_id:"marker-self-comment"}' \
  > "$home/state/linear-outbox/observed-journal.done"
comment_target="$home/dangling-comment-target"
ln -s "$comment_target" "$home/state/linear-outbox/observed-journal.comment-observed"
out=$(run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "unsafe outbox observation marker: observed-journal.comment-observed" \
  "comment observation followed a dangling marker symlink"
[ ! -e "$comment_target" ] || fail "comment observation created the dangling symlink target"
rm -f "$home/state/linear-outbox/observed-journal.comment-observed"
board_target="$home/dangling-board-target"
ln -s "$board_target" "$home/state/linear-outbox/observed-journal.board-observed"
out=$(run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "unsafe outbox observation marker: observed-journal.board-observed" \
  "board observation followed a dangling marker symlink"
[ ! -e "$board_target" ] || fail "board observation created the dangling symlink target"
pass "outbox observation markers reject dangling symlinks"
home=$idempotence_home
fixtures=$idempotence_fixtures

# T2 and T6: a rewind re-reads shuffled records and restores the true maximum.
printf 'comments_updated_at=2026-08-14T10:00:00Z\nissues_updated_at=2026-08-14T10:00:00Z\n' > "$home/state/.linear-cursor"
out=$(run_poll "$home" "$fixtures") || fail "rewound poll failed"
[ -z "$out" ] || fail "rewound duplicate poll was not silent: $out"
grep -qx 'comments_updated_at=2026-08-14T11:58:01.000000000Z' "$home/state/.linear-cursor" \
  || fail "rewind did not restore the maximum comment timestamp"
grep -qx 'issues_updated_at=2026-08-14T11:58:04.000000000Z' "$home/state/.linear-cursor" \
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

home=$(make_home same-hash-edit)
fixtures="$TMP_ROOT/same-hash-edit-one"
first=$(comment same-hash 2026-08-14T11:55:00Z A captain-id shared-name BIG-4)
first=$(printf '%s' "$first" | jq '.editedAt="2026-08-14T11:55:00Z"')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$first" '[$c]')" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "first same-hash edit poll failed"
fixtures="$TMP_ROOT/same-hash-edit-two"
reverted=$(printf '%s' "$first" | jq '.updatedAt="2026-08-14T11:57:00Z" | .editedAt="2026-08-14T11:57:00Z"')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$reverted" '[$c]')" '[]'
out=$(run_poll "$home" "$fixtures") || fail "same-hash edit occurrence poll failed"
assert_contains "$out" "1 captain input(s)" "new editedAt with the same body hash was suppressed"
[ "$(pending_count "$home")" = 2 ] || fail "same-hash edit occurrence was not preserved separately"
pass "editedAt surfaces same-hash edit occurrences"

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

home=$(make_home bounded-bootstrap)
rm -f "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/bounded-bootstrap-page-one"
mkdir -p "$fixtures"
old_one=$(comment old-one 2025-01-01T00:00:00Z old captain-id shared-name BIG-4)
jq -n --argjson node "$old_one" '
  {data:{viewer:{id:"firstmate-id"},comments:{
    pageInfo:{hasNextPage:true,endCursor:"older-page"},nodes:[$node]}}}
' > "$fixtures/01-comment-heads.json"
make_fixtures "$fixtures/normal" '[]' '[]'
mv "$fixtures/normal/01-comments.json" "$fixtures/02-comments.json"
mv "$fixtures/normal/02-issues.json" "$fixtures/03-issues.json"
rmdir "$fixtures/normal"
request_log="$home/bootstrap.log"
FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures" >/dev/null \
  || fail "bounded comment-head bootstrap page one failed"
[ "$(jq -r '.after' "$home/state/.linear-comment-head-bootstrap.json")" = older-page ] \
  || fail "comment-head bootstrap did not retain its resume cursor"
[ "$(jq -r '.complete' "$home/state/.linear-comment-head-bootstrap.json")" = false ] \
  || fail "comment-head bootstrap completed before its final page"
awk -F '\t' '$1 == "comments" { print $2 }' "$request_log" \
  | jq -e '.query | contains("updatedAt:{gte:\"2026-08-14T10:00:00.000000000Z\"}")' >/dev/null \
  || fail "initial captain-event query was not bounded to the bootstrap horizon"
awk -F '\t' '$1 == "issues" { print $2 }' "$request_log" \
  | jq -e '.query | contains("updatedAt:{gte:\"2026-08-14T10:00:00.000000000Z\"}")' >/dev/null \
  || fail "initial issue query was not bounded to the bootstrap horizon"
grep -qx 'comments_updated_at=2026-08-14T10:00:00.000000000Z' "$home/state/.linear-cursor" \
  || fail "empty initial comment ingestion did not establish its bounded cursor"
grep -qx 'issues_updated_at=2026-08-14T10:00:00.000000000Z' "$home/state/.linear-cursor" \
  || fail "empty initial issue ingestion did not establish its bounded cursor"
fixtures="$TMP_ROOT/bounded-bootstrap-page-two"
mkdir -p "$fixtures"
old_two=$(comment old-two 2024-01-01T00:00:00Z older captain-id shared-name BIG-4)
jq -n --argjson node "$old_two" '
  {data:{viewer:{id:"firstmate-id"},comments:{
    pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}
' > "$fixtures/01-comment-heads.json"
make_fixtures "$fixtures/normal" '[]' '[]'
mv "$fixtures/normal/01-comments.json" "$fixtures/02-comments.json"
mv "$fixtures/normal/02-issues.json" "$fixtures/03-issues.json"
rmdir "$fixtures/normal"
run_poll "$home" "$fixtures" >/dev/null || fail "bounded comment-head bootstrap resume failed"
[ "$(jq -r '.complete' "$home/state/.linear-comment-head-bootstrap.json")" = true ] \
  || fail "comment-head bootstrap did not complete after its final page"
[ "$(wc -l < "$home/state/.linear-comment-heads.tsv" | tr -d ' ')" = 2 ] \
  || fail "resumable bootstrap did not retain every historical comment head"
pass "initial bootstrap is bounded and resumes historical comment heads"

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
description_history=$(printf '%s' "$description_history" | jq --arg description "$description" '
  .fromState = null | .toState = null | .updatedDescription = true
  | .changes={description:["old",$description]}
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

home=$(make_home creation-window-description)
fixtures="$TMP_ROOT/creation-window-description-a"
created_a=$(issue BIG-12 2026-08-14T11:58:30Z captain-id shared-name '[]' Backlog firstmate-id shared-name A)
created_a=$(printf '%s' "$created_a" | jq '.createdAt = "2026-08-14T11:58:00Z"')
issues=$(jq -nc --argjson i "$created_a" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
run_poll "$home" "$fixtures" >/dev/null || fail "creation-window description A poll failed"
fixtures="$TMP_ROOT/creation-window-description-b"
created_b=$(issue BIG-12 2026-08-14T11:59:00Z captain-id shared-name '[]' Backlog firstmate-id shared-name B)
created_b=$(printf '%s' "$created_b" | jq '.createdAt = "2026-08-14T11:58:00Z"')
issues=$(jq -nc --argjson i "$created_b" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures" 2>&1) || fail "creation-window description B poll failed: $out"
assert_contains "$out" "1 non-authoritative observation(s)" "history-free creation-window description edit was silent"
jq -s -e 'any(.[]; .kind == "issue-created" and .description == "A")
  and any(.[]; .kind == "description" and .source == "issue-snapshot" and .description == "B")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "creation-window description snapshots did not preserve both observed bodies"
pass "issue snapshots preserve history-free creation-window description edits"

home=$(make_home mixed-history-snapshot)
fixtures="$TMP_ROOT/mixed-history-snapshot-a"
baseline=$(issue BIG-31 2026-08-14T11:56:00Z firstmate-id shared-name '[]' Backlog firstmate-id shared-name A)
baseline=$(printf '%s' "$baseline" | jq '.title="A"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "mixed snapshot baseline poll failed"
fixtures="$TMP_ROOT/mixed-history-snapshot-b"
title_history=$(history mixed-title 2026-08-14T11:57:00Z captain-id shared-name Backlog Backlog)
title_history=$(printf '%s' "$title_history" | jq '.fromState=null | .toState=null | .fromTitle="A" | .toTitle="B"')
changed=$(issue BIG-31 2026-08-14T11:57:01Z firstmate-id shared-name "$(jq -nc --argjson h "$title_history" '[$h]')" Backlog firstmate-id shared-name B)
changed=$(printf '%s' "$changed" | jq '.title="B"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "mixed history and snapshot poll failed"
assert_contains "$out" "1 captain input(s)" "logged title change did not remain authoritative"
assert_contains "$out" "1 non-authoritative observation(s)" "residual description snapshot was lost"
jq -s -e 'any(.[]; .history_id == "mixed-title" and .authority == "captain")
  and any(.[]; .source == "issue-snapshot" and .authority == "unattributed"
    and .changes == {description:"B"})' "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "history fields were not subtracted from the residual snapshot delta"
pass "snapshot fallback preserves every field not represented by history"

home=$(make_home same-field-residual)
fixtures="$TMP_ROOT/same-field-residual-a"
baseline=$(issue BIG-34 2026-08-14T11:56:00Z firstmate-id shared-name '[]')
baseline=$(printf '%s' "$baseline" | jq '.title="A"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "same-field residual baseline failed"
fixtures="$TMP_ROOT/same-field-residual-c"
title_history=$(history residual-title 2026-08-14T11:57:00Z captain-id shared-name Backlog Backlog)
title_history=$(printf '%s' "$title_history" | jq '.fromState=null | .toState=null
  | .fromTitle="A" | .toTitle="B" | .changes={title:["A","B"]}')
changed=$(issue BIG-34 2026-08-14T11:57:01Z firstmate-id shared-name \
  "$(jq -nc --argjson h "$title_history" '[$h]')")
changed=$(printf '%s' "$changed" | jq '.title="C"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "same-field residual poll failed"
assert_contains "$out" "1 captain input(s)" "logged intermediate title did not surface"
assert_contains "$out" "1 non-authoritative observation(s)" "history-suppressed final title was subtracted"
jq -s -e 'any(.[]; .history_id == "residual-title" and .to_title == "B")
  and any(.[]; .source == "issue-snapshot" and .changes.title == "C")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "snapshot reconciliation did not compare the represented target with the current title"
pass "snapshot residuals retain later same-field targets"

home=$(make_home creation-window-board)
fixtures="$TMP_ROOT/creation-window-board-a"
baseline=$(issue BIG-35 2026-08-14T11:56:00Z captain-id shared-name '[]' Backlog firstmate-id shared-name)
baseline=$(printf '%s' "$baseline" | jq '.createdAt="2026-08-14T11:55:30Z" | .state.id="backlog-id"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "creation-window board baseline failed"
fixtures="$TMP_ROOT/creation-window-board-b"
changed=$(printf '%s' "$baseline" | jq '.updatedAt="2026-08-14T11:57:00Z"
  | .state={id:"approve-plan-id",name:"Approve Plan"}
  | .assignee={id:"captain-id",displayName:"shared-name"}')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "creation-window board transition failed"
assert_contains "$out" "1 non-authoritative observation(s)" "history-free board transition was silent"
jq -s -e 'any(.[]; .source == "issue-snapshot"
  and .changes.state.id == "approve-plan-id" and .changes.assignee.id == "captain-id")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "canonical state and assignee IDs were absent from the snapshot delta"
pass "issue snapshots preserve history-free board transitions"

home=$(make_home self-snapshot-board)
fixtures="$TMP_ROOT/self-snapshot-board-a"
baseline=$(issue BIG-45 2026-08-14T11:56:00Z firstmate-id shared-name '[]' Building firstmate-id shared-name)
baseline=$(printf '%s' "$baseline" | jq '.state.id="building-id"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "self snapshot board baseline failed"
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-45",target_state:"Approve Deliverable",state_id:"approve-id",
  assignee_id:"captain-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:57:00Z",comment_id:null}' \
  > "$home/state/linear-outbox/self-snapshot.done"
fixtures="$TMP_ROOT/self-snapshot-board-b"
changed=$(printf '%s' "$baseline" | jq '.updatedAt="2026-08-14T11:57:00Z"
  | .state={id:"approve-id",name:"Approve Deliverable"}
  | .assignee={id:"captain-id",displayName:"shared-name"}')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "proven self snapshot board poll failed"
[ -z "$out" ] || fail "proven self snapshot board mutation produced a wake: $out"
[ "$(pending_count "$home")" = 0 ] || fail "proven self snapshot board mutation entered the inbox"
[ -f "$home/state/linear-outbox/self-snapshot.board-observed" ] \
  || fail "proven self snapshot board mutation did not close observation"
pass "proven self snapshot mutations are suppressed and observed"

home=$(make_home unmatched-snapshot-board)
fixtures="$TMP_ROOT/unmatched-snapshot-board-a"
baseline=$(issue BIG-46 2026-08-14T11:56:00Z firstmate-id shared-name '[]' Building firstmate-id shared-name)
baseline=$(printf '%s' "$baseline" | jq '.state.id="building-id"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "unmatched snapshot board baseline failed"
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-46",target_state:"Approve Deliverable",state_id:"approve-id",
  assignee_id:"captain-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:56:59Z",comment_id:null}' \
  > "$home/state/linear-outbox/wrong-version.done"
jq -n '{issue:"BIG-46",target_state:"Approve Deliverable",state_id:"other-approve-id",
  assignee_id:"captain-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:57:00Z",comment_id:null}' \
  > "$home/state/linear-outbox/wrong-id.done"
fixtures="$TMP_ROOT/unmatched-snapshot-board-b"
changed=$(printf '%s' "$baseline" | jq '.updatedAt="2026-08-14T11:57:00Z"
  | .state={id:"approve-id",name:"Approve Deliverable"}
  | .assignee={id:"captain-id",displayName:"shared-name"}')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "unmatched snapshot board poll failed"
assert_contains "$out" "1 non-authoritative observation(s)" \
  "unmatched snapshot board delta was suppressed as self"
jq -s -e 'any(.[]; .source == "issue-snapshot" and .authority == "unattributed"
  and .changes.state.id == "approve-id" and .changes.assignee.id == "captain-id")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "unmatched snapshot board delta was classified as self"
[ ! -e "$home/state/linear-outbox/wrong-version.board-observed" ] \
  && [ ! -e "$home/state/linear-outbox/wrong-id.board-observed" ] \
  || fail "unmatched snapshot board delta marked an outbox write observed"
pass "snapshot reconciliation requires exact IDs and mutation provenance"

home=$(make_home exact-history-observation)
mkdir -p "$home/state/linear-outbox"
jq -n '{issue:"BIG-49",target_state:"Approve Deliverable",state_id:"approve-id",
  assignee_id:"captain-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:57:00Z",comment_id:null}' \
  > "$home/state/linear-outbox/stale-pair.done"
jq -n '{issue:"BIG-49",target_state:"Approve Deliverable",state_id:"approve-id",
  assignee_id:"captain-id",mutation_sent:true,
  mutated_updated_at:"2026-08-14T11:58:00Z",comment_id:null}' \
  > "$home/state/linear-outbox/exact-pair.done"
fixtures="$TMP_ROOT/exact-history-observation-fixtures"
self_board=$(history exact-self-board 2026-08-14T11:58:00Z firstmate-id shared-name Building 'Approve Deliverable' \
  captain-id shared-name)
self_board=$(printf '%s' "$self_board" | jq '.fromState.id="building-id" | .toState.id="approve-id"')
changed=$(issue BIG-49 2026-08-14T11:58:01Z firstmate-id shared-name \
  "$(jq -nc --argjson h "$self_board" '[$h]')" 'Approve Deliverable' captain-id shared-name)
changed=$(printf '%s' "$changed" | jq '.state.id="approve-id"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "exact history observation poll failed"
[ -f "$home/state/linear-outbox/exact-pair.board-observed" ] \
  || fail "exact mutation history did not satisfy board observation"
[ ! -e "$home/state/linear-outbox/stale-pair.board-observed" ] \
  || fail "a later same-pair history occurrence satisfied stale mutation provenance"
pass "board observation requires exact mutation occurrence provenance"

home=$(make_home description-authority)
fixtures="$TMP_ROOT/description-authority-a"
baseline=$(issue BIG-36 2026-08-14T11:56:00Z firstmate-id shared-name '[]' Backlog firstmate-id shared-name A)
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "description authority baseline failed"
fixtures="$TMP_ROOT/description-authority-c"
description_history=$(history captain-description 2026-08-14T11:56:30Z captain-id shared-name Backlog Backlog)
description_history=$(printf '%s' "$description_history" | jq '.fromState=null | .toState=null
  | .updatedDescription=true | .changes=null')
changed=$(issue BIG-36 2026-08-14T11:57:00Z other-id shared-name \
  "$(jq -nc --argjson h "$description_history" '[$h]')" Backlog firstmate-id shared-name C)
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$changed" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "description authority poll failed"
assert_not_contains "$out" "captain input(s)" "current non-captain description was attributed to older captain history"
assert_contains "$out" "1 non-authoritative observation(s)" "unattributed current description was not durable"
jq -s -e 'all(.[]; .description != "C" or .authority != "captain")
  and any(.[]; .source == "issue-snapshot" and .description == "C" and .authority == "unattributed")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "description snapshot authority was synthesized from an unrelated history actor"
pass "description content keeps occurrence-owned authority"

home=$(make_home bootstrap-horizon-retry)
rm -f "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/bootstrap-horizon-fail"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' \
  > "$fixtures/01-comment-heads.json"
printf '{}\n' > "$fixtures/02-fail-500.json"
run_poll "$home" "$fixtures" >/dev/null 2>&1 && fail "bootstrap failure unexpectedly succeeded"
[ "$(cat "$home/state/.linear-bootstrap-horizon")" = 2026-08-14T10:00:00.000000000Z ] \
  || fail "initial bootstrap horizon was not durably fixed before fetching"
fixtures="$TMP_ROOT/bootstrap-horizon-retry-fixtures"
make_fixtures "$fixtures" '[]' '[]'
request_log="$home/horizon-retry.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_FIXTURE_LOG="$request_log" FM_LINEAR_NOW_EPOCH=$((NOW + 10800)) \
  FM_LINEAR_PENDING_ALARM_SECONDS=9999 "$POLL" >/dev/null \
  || fail "bootstrap horizon retry failed"
awk -F '\t' '$1 == "comments" || $1 == "issues" { print $2 }' "$request_log" \
  | jq -s -e 'length == 2 and all(.[]; .query | contains("updatedAt:{gte:\"2026-08-14T10:00:00.000000000Z\"}"))' \
  >/dev/null || fail "cursorless retry drifted its initial ingestion horizon"
[ ! -e "$home/state/.linear-bootstrap-horizon" ] || fail "completed cursor establishment retained a stale horizon"
pass "cursorless retries reuse one durable bootstrap horizon"

home=$(make_home incomplete-head-bump)
rm -f "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/incomplete-head-bump-fixtures"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:true,endCursor:"next-old-page"},nodes:[]}}}' \
  > "$fixtures/01-comment-heads.json"
unseeded=$(comment unseeded-old 2026-08-14T11:58:00Z unchanged captain-id shared-name BIG-13)
unseeded=$(printf '%s' "$unseeded" | jq '.createdAt="2025-01-01T00:00:00Z"')
make_fixtures "$fixtures/normal" "$(jq -nc --argjson c "$unseeded" '[$c]')" '[]'
mv "$fixtures/normal/01-comments.json" "$fixtures/02-comments.json"
mv "$fixtures/normal/02-issues.json" "$fixtures/03-issues.json"
rmdir "$fixtures/normal"
out=$(run_poll "$home" "$fixtures") || fail "incomplete-head unchanged bump poll failed"
[ -z "$out" ] || fail "unseeded old reply bump woke while bootstrap was incomplete: $out"
[ "$(pending_count "$home")" = 0 ] || fail "unseeded old reply bump created a captain event"
pass "incomplete head bootstrap lazily silences old reply bumps"

home=$(make_home incomplete-head-edit)
rm -f "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/incomplete-head-edit-fixtures"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:true,endCursor:"next-old-page"},nodes:[]}}}' \
  > "$fixtures/01-comment-heads.json"
unseeded=$(comment unseeded-edit 2026-08-14T11:58:00Z changed captain-id shared-name BIG-13)
unseeded=$(printf '%s' "$unseeded" | jq '.createdAt="2025-01-01T00:00:00Z" | .editedAt=.updatedAt')
make_fixtures "$fixtures/normal" "$(jq -nc --argjson c "$unseeded" '[$c]')" '[]'
mv "$fixtures/normal/01-comments.json" "$fixtures/02-comments.json"
mv "$fixtures/normal/02-issues.json" "$fixtures/03-issues.json"
rmdir "$fixtures/normal"
out=$(run_poll "$home" "$fixtures") || fail "incomplete-head actual edit poll failed"
assert_contains "$out" "1 captain input(s)" "editedAt did not distinguish an old actual edit from a reply bump"
pass "incomplete head bootstrap still surfaces actual old-comment edits"

home=$(make_home incomplete-thread-participation)
rm -f "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/incomplete-thread-participation-fixtures"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:true,endCursor:"next-old-page"},nodes:[]}}}' \
  > "$fixtures/01-comment-heads.json"
reply=$(comment bootstrap-thread-reply 2026-08-14T11:58:00Z followup captain-id shared-name BIG-31)
reply=$(printf '%s' "$reply" | jq '.issue.labels.nodes=[] | .parent={id:"unscanned-firstmate-root"}')
jq -n --argjson node "$reply" \
  '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{
    pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}' \
  > "$fixtures/02-comments.json"
jq -n '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' \
  > "$fixtures/03-issues.json"
jq -n '{data:{comment:{id:"unscanned-firstmate-root",issue:{identifier:"BIG-31"},parent:null,
  user:{id:"firstmate-id"}}}}' > "$fixtures/04-thread-root.json"
out=$(run_poll "$home" "$fixtures") || fail "incomplete thread-participation poll failed"
assert_contains "$out" "1 captain input(s)" \
  "captain reply was suppressed before historical Firstmate participation was known"
jq -s -e 'any(.[]; .comment_id == "bootstrap-thread-reply"
  and .thread_id == "unscanned-firstmate-root" and .route == "thread")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "bootstrap reply did not persist its resolved canonical thread"
pass "incomplete bootstrap resolves thread participation before suppression"

home=$(make_home thread-routing)
fixtures="$TMP_ROOT/thread-routing-ignored"
bare=$(comment bare-unlabelled 2026-08-14T11:55:00Z hello captain-id shared-name BIG-14)
bare=$(printf '%s' "$bare" | jq '.issue.labels.nodes=[]')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$bare" '[$c]')" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "unlabelled bare comment poll failed"
[ "$(pending_count "$home")" = 0 ] || fail "unlabelled bare comment started a thread without a mention"
fixtures="$TMP_ROOT/thread-routing-mention"
mentioned=$(comment thread-root 2026-08-14T11:56:00Z '@josh.padnickfirstmate please look' captain-id shared-name BIG-14)
mentioned=$(printf '%s' "$mentioned" | jq '.issue.labels.nodes=[]')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$mentioned" '[$c]')" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "unlabelled mentioned comment poll failed"
fixtures="$TMP_ROOT/thread-routing-self"
self_reply=$(comment self-thread-reply 2026-08-14T11:57:00Z acknowledged firstmate-id shared-name BIG-14)
self_reply=$(printf '%s' "$self_reply" | jq '.issue.labels.nodes=[] | .parent={id:"thread-root"}')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$self_reply" '[$c]')" '[]'
jq -n '{data:{comment:{id:"thread-root",issue:{identifier:"BIG-14"},parent:null,
  user:{id:"captain-id"}}}}' > "$fixtures/03-thread-root.json"
run_poll "$home" "$fixtures" >/dev/null || fail "Firstmate thread participation poll failed"
fixtures="$TMP_ROOT/thread-routing-followup"
followup=$(comment bare-followup 2026-08-14T11:58:00Z followup captain-id shared-name BIG-14)
followup=$(printf '%s' "$followup" | jq '.issue.labels.nodes=[] | .parent={id:"thread-root"}')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$followup" '[$c]')" '[]'
jq -n '{data:{comment:{id:"thread-root",issue:{identifier:"BIG-14"},parent:null,
  user:{id:"captain-id"}}}}' > "$fixtures/03-thread-root.json"
out=$(run_poll "$home" "$fixtures") || fail "participated-thread follow-up poll failed"
assert_contains "$out" "1 captain input(s)" "bare follow-up after Firstmate participation was silent"
jq -s -e 'any(.[]; .comment_id == "thread-root" and .route == "mention")
  and any(.[]; .comment_id == "bare-followup" and .route == "thread")' \
  "$home/state/linear-inbox"/*.json >/dev/null || fail "durable comment routes did not encode mention and thread continuation"
pass "comment routing persists Firstmate thread participation"

home=$(make_home nested-thread-routing)
fixtures="$TMP_ROOT/nested-thread-self"
nested_self=$(comment nested-self 2026-08-14T11:57:00Z acknowledged firstmate-id shared-name BIG-33)
nested_self=$(printf '%s' "$nested_self" | jq '.issue.labels.nodes=[] | .parent={id:"thread-child"}')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$nested_self" '[$c]')" '[]'
jq -n '{data:{comment:{id:"thread-child",issue:{identifier:"BIG-33"},parent:{id:"thread-root"},
  user:{id:"captain-id"}}}}' > "$fixtures/03-thread-child.json"
jq -n '{data:{comment:{id:"thread-root",issue:{identifier:"BIG-33"},parent:null,
  user:{id:"captain-id"}}}}' > "$fixtures/04-thread-root.json"
run_poll "$home" "$fixtures" >/dev/null || fail "nested Firstmate participation poll failed"
awk -F '\t' '$1 == "thread-root" { found=1 } END { exit !found }' \
  "$home/state/.linear-thread-participation.tsv" \
  || fail "nested Firstmate reply retained its immediate parent instead of the canonical root"
fixtures="$TMP_ROOT/nested-thread-followup"
nested_followup=$(comment nested-followup 2026-08-14T11:58:00Z followup captain-id shared-name BIG-33)
nested_followup=$(printf '%s' "$nested_followup" | jq '.issue.labels.nodes=[] | .parent={id:"thread-root"}')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$nested_followup" '[$c]')" '[]'
jq -n '{data:{comment:{id:"thread-root",issue:{identifier:"BIG-33"},parent:null,
  user:{id:"captain-id"}}}}' > "$fixtures/03-thread-root.json"
out=$(run_poll "$home" "$fixtures") || fail "nested-thread captain follow-up poll failed"
assert_contains "$out" "1 captain input(s)" "canonical nested-thread participation did not wake the later root reply"
pass "nested participation is retained at the canonical thread root"

home=$(make_home label-only-ownership)
fixtures="$TMP_ROOT/label-only-ownership-fixtures"
assigned=$(issue BIG-15 2026-08-14T11:58:00Z captain-id shared-name '[]' Backlog firstmate-id shared-name 'firstmate please own')
assigned=$(printf '%s' "$assigned" | jq '.createdAt="2026-08-14T11:57:59Z" | .labels.nodes=[]')
labelled=$(issue BIG-16 2026-08-14T11:58:01Z captain-id shared-name '[]')
labelled=$(printf '%s' "$labelled" | jq '.createdAt="2026-08-14T11:58:00Z"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson a "$assigned" --argjson b "$labelled" '[$a,$b]')"
run_poll "$home" "$fixtures" >/dev/null || fail "label-only ownership poll failed"
jq -s -e 'length == 1 and .[0].kind == "issue-created" and .[0].issue == "BIG-16"' \
  "$home/state/linear-inbox"/*.json >/dev/null || fail "assignment or body mention established new-issue ownership without the label"
pass "new issue ownership is established only by the Firstmate label"

home=$(make_home label-acquisition)
fixtures="$TMP_ROOT/label-acquisition-before"
unlabelled=$(issue BIG-32 2026-08-14T11:57:00Z captain-id shared-name '[]')
unlabelled=$(printf '%s' "$unlabelled" | jq '.createdAt="2026-08-14T11:56:30Z" | .labels.nodes=[]')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$unlabelled" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "unlabelled creation baseline poll failed"
[ "$(pending_count "$home")" = 0 ] || fail "unlabelled creation established Firstmate ownership"
fixtures="$TMP_ROOT/label-acquisition-after"
labelled=$(printf '%s' "$unlabelled" | jq '.updatedAt="2026-08-14T11:58:00Z"
  | .labels.nodes=[{name:"Firstmate"}]')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$labelled" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "creation-window label acquisition poll failed"
jq -s -e 'length == 1 and .[0].kind == "label" and .[0].issue == "BIG-32"
  and .[0].source == "issue-snapshot" and .[0].ownership_acquired == true
  and .[0].changes.labels == ["Firstmate"]' "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "creation-window Firstmate label acquisition was not durable"
pass "issue snapshots preserve Firstmate ownership acquired during creation"

home=$(make_home amended-history)
fixtures="$TMP_ROOT/amended-history-a"
title_history=$(history amended-title 2026-08-14T11:58:00Z captain-id shared-name Backlog Backlog)
title_history=$(printf '%s' "$title_history" | jq '.fromState=null | .toState=null
  | .fromTitle="A" | .toTitle="B" | .fromPriority=1 | .toPriority=2
  | .fromProject={id:"p1",name:"Old"} | .toProject={id:"p2",name:"New"}
  | .fromParent={id:"i1",identifier:"BIG-1"} | .toParent={id:"i2",identifier:"BIG-2"}
  | .fromDueDate="2026-08-20" | .toDueDate="2026-08-21"
  | .changes={title:["A","B"],priority:[1,2]}')
title_history_a=$title_history
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$(issue BIG-17 2026-08-14T11:58:01Z captain-id shared-name "$(jq -nc --argjson h "$title_history" '[ $h ]')")" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "first amended history poll failed"
fixtures="$TMP_ROOT/amended-history-b"
title_history=$(printf '%s' "$title_history" | jq '.updatedAt="2026-08-14T11:59:00Z" | .toTitle="C" | .changes={title:["A","C"]}')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$(issue BIG-17 2026-08-14T11:59:01Z captain-id shared-name "$(jq -nc --argjson h "$title_history" '[ $h ]')")" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "amended history poll failed"
assert_contains "$out" "1 captain input(s)" "content-amended history ID was suppressed"
jq -s -e 'map(select(.history_id == "amended-title")) | length == 2
  and any(.[]; .kind == "issue-change" and .to_title == "C" and .to_priority == 2
    and .to_project.id == "p2" and .to_parent.identifier == "BIG-2"
    and .to_due_date == "2026-08-21")' \
  "$home/state/linear-inbox"/*.json >/dev/null || fail "amended title history was not preserved by derived content"
[ "$(wc -l < "$home/state/.linear-history-heads.tsv" | tr -d ' ')" = 1 ] \
  || fail "amended history retained more than one latest content head"
fixtures="$TMP_ROOT/amended-history-revert"
title_history=$(printf '%s' "$title_history_a" | jq '.updatedAt="2026-08-14T12:00:00Z"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$(issue BIG-17 2026-08-14T12:00:01Z captain-id shared-name "$(jq -nc --argjson h "$title_history" '[ $h ]')")" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "reverted history amendment poll failed"
assert_contains "$out" "1 captain input(s)" "A-to-B-to-A history amendment collided with the first A occurrence"
jq -s -e 'map(select(.history_id == "amended-title")) | length == 3
  and (map(select(.history_id == "amended-title" and .to_title == "B")) | length == 2)' \
  "$home/state/linear-inbox"/*.json >/dev/null || fail "history occurrences did not retain both repeated A targets"
pass "history occurrence keys preserve A-to-B-to-A amendments"

home=$(make_home deep-history-overlap)
printf 'comments_updated_at=2026-08-14T12:00:00Z\nissues_updated_at=2026-08-14T12:00:00Z\n' > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/deep-history-overlap-fixtures"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' \
  > "$fixtures/01-comments.json"
histories=$(jq -nc '[range(0;10) as $n | {id:("recent-"+($n|tostring)),
  createdAt:"2026-08-14T11:56:00Z",updatedAt:"2026-08-14T11:56:00Z",changes:null,
  actor:{id:"captain-id",displayName:"shared-name"},fromState:null,toState:null,
  fromAssignee:null,toAssignee:null,fromTitle:"A",toTitle:"B",updatedDescription:false,
  addedLabels:[],removedLabels:[]}]')
deep_issue=$(issue BIG-20 2026-08-14T11:59:00Z captain-id shared-name "$histories")
deep_issue=$(printf '%s' "$deep_issue" | jq '.history.pageInfo={hasNextPage:true,endCursor:"deep-page"}')
jq -n --argjson node "$deep_issue" \
  '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}' \
  > "$fixtures/02-issues.json"
old_history=$(history old-boundary 2026-08-14T11:54:00Z captain-id shared-name Backlog Building)
jq -n --argjson node "$old_history" \
  '{data:{issue:{description:"",history:{pageInfo:{hasNextPage:true,endCursor:"too-old"},nodes:[$node]}}}}' \
  > "$fixtures/03-history.json"
request_log="$home/deep-history.log"
FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures" >/dev/null \
  || fail "deep history overlap poll failed"
[ "$(awk -F '\t' '$1=="history"{n++} END{print n+0}' "$request_log")" = 1 ] \
  || fail "deep history pagination continued beyond the overlap horizon"
awk -F '\t' '$1=="issues"{print $2}' "$request_log" \
  | jq -e '.query | contains("history(first:10,orderBy:updatedAt)")' >/dev/null \
  || fail "initial history pages were not ordered by amendment time"
awk -F '\t' '$1=="history"{print $2}' "$request_log" \
  | jq -e '.query | contains("history(first:10,after:$after,orderBy:updatedAt)")' >/dev/null \
  || fail "deep history pages were not ordered by amendment time"
jq -s -e 'all(.[]; .history_id != "old-boundary")' "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "history older than the overlap horizon became a captain event"
pass "deep history pagination stops at the overlap horizon"

home=$(make_home resumable-deep-history)
printf 'comments_updated_at=2026-08-14T12:00:00Z\nissues_updated_at=2026-08-14T12:00:00Z\n' \
  > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/resumable-deep-history-one"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' \
  > "$fixtures/01-comments.json"
histories=$(jq -nc '[range(0;10) as $n | {id:("scan-initial-"+($n|tostring)),
  createdAt:"2026-08-14T11:58:00Z",updatedAt:"2026-08-14T11:58:00Z",changes:{title:["A","B"]},
  actor:{id:"captain-id",displayName:"shared-name"},fromState:null,toState:null,
  fromAssignee:null,toAssignee:null,fromTitle:"A",toTitle:"B",updatedDescription:false,
  addedLabels:[],removedLabels:[]}]')
scan_issue=$(issue BIG-37 2026-08-14T12:01:00Z captain-id shared-name "$histories")
scan_issue=$(printf '%s' "$scan_issue" | jq '.createdAt="2026-08-14T11:56:00Z"
  | .state={id:"qa-id",name:"QA"}
  | .history.pageInfo={hasNextPage:true,endCursor:"scan-page-one"}')
later_issue=$(issue BIG-38 2026-08-14T12:10:00Z captain-id shared-name '[]')
later_issue=$(printf '%s' "$later_issue" | jq '.createdAt="2026-08-14T12:09:30Z"')
jq -n --argjson a "$scan_issue" --argjson b "$later_issue" \
  '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$a,$b]}}}' \
  > "$fixtures/02-issues.json"
scan_page=$(history scan-middle 2026-08-14T11:57:30Z captain-id shared-name Backlog Building)
jq -n --argjson node "$scan_page" \
  '{data:{issue:{history:{pageInfo:{hasNextPage:true,endCursor:"scan-page-two"},nodes:[$node]}}}}' \
  > "$fixtures/03-history.json"
out=$(FM_LINEAR_HISTORY_PAGES_PER_POLL=1 run_poll "$home" "$fixtures") \
  || fail "first resumable deep-history poll failed"
assert_contains "$out" "BIG-38" "deep scan blocked a later captain issue"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-37)" \
  "deep history scan hid the fetched issue's unknown status"
[ -f "$home/state/.linear-history-scans/BIG-37.json" ] \
  || fail "incomplete deep-history pagination was not checkpointed durably"
grep -qx 'issues_updated_at=2026-08-14T12:10:00.000000000Z' "$home/state/.linear-cursor" \
  || fail "an incomplete issue scan blocked the global issue cursor"
fixtures="$TMP_ROOT/resumable-deep-history-two"
make_fixtures "$fixtures" '[]' '[]'
scan_page=$(history scan-final 2026-08-14T11:57:00Z captain-id shared-name Building Backlog)
jq -n --argjson node "$scan_page" \
  '{data:{issue:{history:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}}' \
  > "$fixtures/03-history.json"
out=$(FM_LINEAR_HISTORY_PAGES_PER_POLL=1 run_poll "$home" "$fixtures") \
  || fail "resumed deep-history poll failed"
[ ! -e "$home/state/.linear-history-scans/BIG-37.json" ] \
  || fail "completed deep-history scan retained its checkpoint"
jq -s -e 'any(.[]; .history_id == "scan-middle") and any(.[]; .history_id == "scan-final")
  and any(.[]; .kind == "issue-created" and .issue == "BIG-37")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "resumed deep-history horizon did not preserve history and creation events"
pass "deep history checkpoints retain their original ingestion horizon"

home=$(make_home deep-history-snapshots)
fixtures="$TMP_ROOT/deep-history-snapshot-baseline"
baseline=$(issue BIG-48 2026-08-14T11:55:00Z captain-id shared-name '[]' Backlog firstmate-id shared-name A)
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$baseline" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "deep-history snapshot baseline failed"
histories=$(jq -nc '[range(0;10) as $n | {id:("snapshot-initial-"+($n|tostring)),
  createdAt:"2026-08-14T11:54:00Z",updatedAt:"2026-08-14T11:54:00Z",changes:null,
  actor:{id:"captain-id",displayName:"shared-name"},fromState:null,toState:null,
  fromAssignee:null,toAssignee:null,updatedDescription:false,addedLabels:[],removedLabels:[]}]')
fixtures="$TMP_ROOT/deep-history-snapshot-b"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{
  pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/01-comments.json"
snapshot_b=$(issue BIG-48 2026-08-14T11:56:00Z captain-id shared-name "$histories" \
  Backlog firstmate-id shared-name B)
snapshot_b=$(printf '%s' "$snapshot_b" | jq '.history.pageInfo={hasNextPage:true,endCursor:"snapshot-page-one"}')
jq -n --argjson issue "$snapshot_b" \
  '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$issue]}}}' \
  > "$fixtures/02-issues.json"
middle=$(history snapshot-middle 2026-08-14T11:53:00Z captain-id shared-name Backlog Backlog)
middle=$(printf '%s' "$middle" | jq '.fromState=null | .toState=null')
jq -n --argjson node "$middle" \
  '{data:{issue:{history:{pageInfo:{hasNextPage:true,endCursor:"snapshot-page-two"},nodes:[$node]}}}}' \
  > "$fixtures/03-history.json"
run_poll "$home" "$fixtures" >/dev/null || fail "first deep-history snapshot sweep failed"
jq -e '.snapshots | length == 1 and .[0].description == "B"' \
  "$home/state/.linear-history-scans/BIG-48.json" >/dev/null \
  || fail "incomplete deep scan did not durably retain snapshot B"
fixtures="$TMP_ROOT/deep-history-snapshot-c"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{
  pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/01-comments.json"
snapshot_c=$(printf '%s' "$snapshot_b" | jq '.updatedAt="2026-08-14T11:57:00Z" | .description="C"')
jq -n --argjson issue "$snapshot_c" \
  '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$issue]}}}' \
  > "$fixtures/02-issues.json"
final=$(history snapshot-final 2026-08-14T11:49:00Z captain-id shared-name Backlog Backlog)
final=$(printf '%s' "$final" | jq '.fromState=null | .toState=null')
jq -n --argjson node "$final" \
  '{data:{issue:{history:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}}' \
  > "$fixtures/03-history.json"
out=$(run_poll "$home" "$fixtures") || fail "completed deep-history snapshot sweep failed"
assert_contains "$out" "2 non-authoritative observation(s)" \
  "deep scan completion collapsed fetched snapshots B and C"
jq -s -e 'map(select(.issue == "BIG-48" and .source == "issue-snapshot")) as $events
  | ($events | length) == 2
  and any($events[]; .description == "B" and .changes.description == "B")
  and any($events[]; .description == "C" and .changes.description == "C")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "deep scan did not reconcile every retained snapshot version in order"
pass "deep history scans preserve every fetched snapshot version"

home=$(make_home deep-scan-turn-mismatch)
printf 'comments_updated_at=2026-08-14T12:00:00Z\nissues_updated_at=2026-08-14T12:00:00Z\n' \
  > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/deep-scan-turn-mismatch-fixtures"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{
  pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/01-comments.json"
histories=$(jq -nc '[range(0;10) as $n | {id:("mismatch-history-"+($n|tostring)),
  createdAt:"2026-08-14T11:58:00Z",updatedAt:"2026-08-14T11:58:00Z",changes:null,
  actor:{id:"captain-id",displayName:"shared-name"},fromState:null,toState:null,
  fromAssignee:null,toAssignee:null,updatedDescription:false,addedLabels:[],removedLabels:[]}]')
scan_issue=$(issue BIG-47 2026-08-14T12:01:00Z captain-id shared-name "$histories" \
  'Approve Deliverable' firstmate-id shared-name)
scan_issue=$(printf '%s' "$scan_issue" | jq '.state.id="approve-id"
  | .history.pageInfo={hasNextPage:true,endCursor:"mismatch-page-one"}')
jq -n --argjson issue "$scan_issue" \
  '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$issue]}}}' \
  > "$fixtures/02-issues.json"
jq -n '{data:{issue:{history:{pageInfo:{hasNextPage:true,endCursor:"mismatch-page-two"},nodes:[]}}}}' \
  > "$fixtures/03-history.json"
out=$(FM_LINEAR_HISTORY_PAGES_PER_POLL=1 run_poll "$home" "$fixtures") \
  || fail "deep scan turn-marker audit failed"
assert_contains "$out" "TURN-MARKER MISMATCH BIG-47" \
  "deep history scan hid the fetched issue's turn-marker mismatch"
pass "fresh issue invariants remain loud during deep history scans"

home=$(make_home nested-thread-resume)
printf 'comments_updated_at=2026-08-14T12:00:00Z\nissues_updated_at=2026-08-14T12:00:00Z\n' \
  > "$home/state/.linear-cursor"
printf '{"after":null,"before":"2026-08-14T11:55:00.000000000Z","complete":false}\n' \
  > "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/nested-thread-resume-one"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:true,endCursor:"older"},nodes:[]}}}' \
  > "$fixtures/01-bootstrap.json"
captain_reply=$(comment nested-captain 2026-08-14T11:58:00Z 'bare nested reply' captain-id shared-name BIG-41)
captain_reply=$(printf '%s' "$captain_reply" | jq '.issue.labels.nodes=[] | .parent={id:"root-comment"}')
jq -n --argjson node "$captain_reply" \
  '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}' \
  > "$fixtures/02-comments.json"
jq -n '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/03-issues.json"
jq -n '{data:{comment:{id:"root-comment",issue:{identifier:"BIG-41"},parent:null,user:{id:"captain-id"}}}}' \
  > "$fixtures/04-root.json"
jq -n '{data:{comment:{id:"root-comment",issue:{identifier:"BIG-41"},children:{
  pageInfo:{hasNextPage:true,endCursor:"root-page-two"},nodes:[{id:"child-earlier",user:{id:"other-id"}}]}}}}' \
  > "$fixtures/05-root-children.json"
nested_status=0
out=$(FM_LINEAR_THREAD_PAGES_PER_POLL=1 run_poll "$home" "$fixtures" 2>&1) || nested_status=$?
[ "$nested_status" -eq 0 ] || fail "first nested participation sweep failed: $out"
[ "$(pending_count "$home")" = 0 ] || fail "incomplete descendant traversal published the reply early"
[ -d "$home/state/.linear-thread-descendant-scans" ] \
  || fail "descendant traversal did not checkpoint provider progress"
scan=$(find "$home/state/.linear-thread-descendant-scans" -type f -name '*.json' | head -n 1)
jq -e '.after == "root-page-two" and .children == ["child-earlier"]' "$scan" >/dev/null \
  || fail "descendant traversal did not checkpoint the earlier child page with its cursor"
fixtures="$TMP_ROOT/nested-thread-resume-two"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:true,endCursor:"oldest"},nodes:[]}}}' \
  > "$fixtures/01-bootstrap.json"
jq -n --argjson node "$captain_reply" \
  '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}' \
  > "$fixtures/02-comments.json"
jq -n '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/03-issues.json"
jq -n '{data:{comment:{id:"root-comment",issue:{identifier:"BIG-41"},children:{
  pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"child-later",user:{id:"other-id"}}]}}}}' \
  > "$fixtures/04-root-children.json"
out=$(FM_LINEAR_THREAD_PAGES_PER_POLL=1 run_poll "$home" "$fixtures") \
  || fail "second nested participation sweep failed"
[ "$(pending_count "$home")" = 0 ] || fail "completed parent pagination published the reply early"
scan=$(find "$home/state/.linear-thread-descendant-scans" -type f -name '*.json' | head -n 1)
jq -e '.after == null and .children == []
  and .queue == ["child-earlier","child-later"]' "$scan" >/dev/null \
  || fail "descendant traversal discarded a child from an earlier page"
fixtures="$TMP_ROOT/nested-thread-resume-three"
mkdir -p "$fixtures"
jq -n '{data:{viewer:{id:"firstmate-id"},comments:{pageInfo:{hasNextPage:true,endCursor:"oldest"},nodes:[]}}}' \
  > "$fixtures/01-bootstrap.json"
jq -n --argjson node "$captain_reply" \
  '{data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[$node]}}}' \
  > "$fixtures/02-comments.json"
jq -n '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$fixtures/03-issues.json"
jq -n '{data:{comment:{id:"child-earlier",issue:{identifier:"BIG-41"},children:{
  pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"nested-self",user:{id:"firstmate-id"}}]}}}}' \
  > "$fixtures/04-child-children.json"
out=$(FM_LINEAR_THREAD_PAGES_PER_POLL=1 run_poll "$home" "$fixtures") \
  || fail "resumed nested participation sweep failed"
assert_contains "$out" "1 captain input(s)" \
  "nested Firstmate participation did not wake the deferred captain reply"
jq -s -e 'any(.[]; .comment_id == "nested-captain" and .route == "thread")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "deferred nested reply was not durably routed through its canonical thread"
pass "nested participation retains every paginated descendant before suppression"

home=$(make_home root-progress-resume)
fixtures="$TMP_ROOT/root-progress-resume-one"
mkdir -p "$fixtures"
root_reply=$(comment root-progress-reply 2026-08-14T11:58:00Z 'root progress' captain-id shared-name BIG-43)
root_reply=$(printf '%s' "$root_reply" | jq '.parent={id:"child-comment"}')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$root_reply" '[$c]')" '[]'
jq -n '{data:{comment:{id:"child-comment",issue:{identifier:"BIG-43"},parent:{id:"root-comment"},user:{id:"other-id"}}}}' \
  > "$fixtures/03-child-root.json"
run_poll "$home" "$fixtures" >/dev/null 2>&1 \
  && fail "incomplete root fixture unexpectedly completed"
scan=$(find "$home/state/.linear-thread-root-scans" -type f -name '*.json' | head -n 1)
[ -n "$scan" ] && [ "$(jq -r '.current' "$scan")" = root-comment ] \
  || fail "canonical-root traversal did not checkpoint its last provider edge"
fixtures="$TMP_ROOT/root-progress-resume-two"
make_fixtures "$fixtures" "$(jq -nc --argjson c "$root_reply" '[$c]')" '[]'
jq -n '{data:{comment:{id:"root-comment",issue:{identifier:"BIG-43"},parent:null,user:{id:"captain-id"}}}}' \
  > "$fixtures/03-root.json"
request_log="$home/root-progress.log"
out=$(FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures") \
  || fail "canonical-root traversal did not resume"
assert_contains "$out" "1 captain input(s)" "resumed root traversal starved later captain input"
awk -F '\t' '$1 == "threadRoot" { print $2 }' "$request_log" \
  | jq -e '.variables.comment == "root-comment"' >/dev/null \
  || fail "resumed root traversal restarted from the already-checkpointed child"
pass "canonical-root traversal resumes from durable edge progress"

home=$(make_home cursor-clamp)
printf 'comments_updated_at=2026-08-14T12:00:00Z\nissues_updated_at=2026-08-14T12:00:00Z\n' > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/cursor-clamp-fixtures"
older=$(comment older-visible 2026-08-14T11:59:00Z old captain-id shared-name BIG-18)
lagged=$(issue BIG-19 2026-08-14T11:59:01Z captain-id shared-name '[]')
lagged=$(printf '%s' "$lagged" | jq '.createdAt="2026-08-14T11:58:00Z"')
make_fixtures "$fixtures" "$(jq -nc --argjson c "$older" '[$c]')" \
  "$(jq -nc --argjson i "$lagged" '[$i]')"
request_log="$home/overlap.log"
out=$(FM_LINEAR_FIXTURE_LOG="$request_log" run_poll "$home" "$fixtures") || fail "monotonic cursor clamp poll failed"
grep -qx 'comments_updated_at=2026-08-14T12:00:00Z' "$home/state/.linear-cursor" \
  || fail "deleted newest comment moved the cursor backwards"
grep -qx 'issues_updated_at=2026-08-14T12:00:00Z' "$home/state/.linear-cursor" \
  || fail "empty issue page moved the cursor backwards"
awk -F '\t' '$1 == "comments" || $1 == "issues" { print $2 }' "$request_log" \
  | jq -s -e 'length == 2 and all(.[]; .query | contains("updatedAt:{gte:\"2026-08-14T11:55:00.000000000Z\"}"))' \
  >/dev/null || fail "incremental polling did not use the five-minute overlap"
jq -s -e 'any(.[]; .kind == "issue-created" and .issue == "BIG-19")' \
  "$home/state/linear-inbox"/*.json >/dev/null || fail "lagged issue creation inside overlap was skipped"
pass "cursor maxima clamp monotonically while creation and queries retain overlap"

home=$(make_home fractional-boundary)
printf 'comments_updated_at=2026-08-14T12:00:00Z\nissues_updated_at=2026-08-14T12:00:00Z\n' \
  > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/fractional-boundary-fixtures"
boundary=$(comment fractional-boundary 2026-08-14T11:55:00.500Z inside captain-id shared-name BIG-39)
make_fixtures "$fixtures" "$(jq -nc --argjson c "$boundary" '[$c]')" '[]'
out=$(run_poll "$home" "$fixtures") || fail "fractional boundary poll failed"
assert_contains "$out" "1 captain input(s)" \
  "fractional event inside the cutoff second compared before the whole-second boundary"
jq -s -e 'any(.[]; .comment_id == "fractional-boundary"
  and .updated_at == "2026-08-14T11:55:00.500000000Z")' \
  "$home/state/linear-inbox"/*.json >/dev/null \
  || fail "fractional event timestamp was not normalized to fixed precision"
pass "fractional timestamps compare correctly at overlap boundaries"

home=$(make_home retained-issue-creation)
printf 'comments_updated_at=2026-08-14T11:55:00Z\nissues_updated_at=2026-08-14T11:55:00Z\n' \
  > "$home/state/.linear-cursor"
fixtures="$TMP_ROOT/retained-issue-creation-fixtures"
created=$(issue BIG-40 2026-08-14T11:58:00Z captain-id shared-name '[]')
created=$(printf '%s' "$created" | jq '.createdAt="2026-08-14T11:57:59Z"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$created" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "retained issue-creation baseline failed"
[ "$(pending_count "$home")" = 1 ] || fail "issue creation baseline was not durable"
for file in "$home/state/linear-inbox"/*.json; do
  : > "${file%.json}.handled"
  rm -f -- "$file" "${file%.json}.handled"
done
printf 'comments_updated_at=2026-08-14T11:55:00Z\nissues_updated_at=2026-08-14T11:55:00Z\n' \
  > "$home/state/.linear-cursor"
out=$(run_poll "$home" "$fixtures") || fail "rewound retained issue-creation poll failed"
[ -z "$out" ] || fail "retained issue creation replayed after event retention: $out"
[ "$(pending_count "$home")" = 0 ] || fail "persistent issue head did not suppress recreated issue input"
pass "issue heads retain immutable creation identity"

home=$(make_home guarded-acknowledgment)
fixtures="$TMP_ROOT/guarded-acknowledgment-fixtures"
comments=$(jq -nc --argjson c "$(comment ack-event 2026-08-14T11:58:00Z acknowledge captain-id shared-name BIG-42)" '[$c]')
make_fixtures "$fixtures" "$comments" '[]'
run_poll "$home" "$fixtures" >/dev/null || fail "acknowledgment baseline poll failed"
event=$(find "$home/state/linear-inbox" -type f -name '*.json' | head -n 1)
event_name=${event##*/}
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLL" acknowledge "$event_name" >/dev/null \
  || fail "guarded event acknowledgment failed"
marker="${event%.json}.handled"
[ -f "$marker" ] && [ ! -L "$marker" ] || fail "acknowledgment did not publish a safe marker"
rm -f -- "$marker"
ln -s "$event" "$marker"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLL" acknowledge "$event_name" >/dev/null 2>&1 \
  && fail "acknowledgment accepted a symlink marker"
pass "handled acknowledgments reject unsafe marker paths"

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

fake_time_bin="$TMP_ROOT/fake-time-bin"
mkdir -p "$fake_time_bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in *2026-08-14T12:00:00Z*) printf "1786712400\\n"; exit 0 ;; esac' \
  'exec /bin/date "$@"' > "$fake_time_bin/date"
chmod +x "$fake_time_bin/date"
home=$(make_home time-self-check)
fixtures="$TMP_ROOT/time-self-check-fixtures"
make_fixtures "$fixtures" '[]' '[]'
out=$(PATH="$fake_time_bin:$PATH" run_poll "$home" "$fixtures" 2>&1 || true)
assert_contains "$out" "UTC timestamp conversion self-check failed" \
  "poll startup accepted the historical plus-one-hour conversion regression"
pass "poll startup rejects a plus-one-hour UTC conversion regression"

# T9 and T11: old pending inputs and turn-marker drift announce every sweep.
home=$(make_home alarms)
fixtures="$TMP_ROOT/alarm-fixtures"
bad_issue=$(issue BIG-9 2026-08-14T11:59:00Z firstmate-id shared-name '[]' 'Approve Deliverable' impostor-id josh.padnick)
issues=$(jq -nc --argjson i "$bad_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
mkdir -p "$home/state/linear-inbox"
jq -n '{kind:"comment",issue:"BIG-8",authority:"captain",created_at:"2026-08-14T11:40:00Z"}' \
  > "$home/state/linear-inbox/stale.json"
chmod 0700 "$home/state/linear-inbox"
chmod 0600 "$home/state/linear-inbox/stale.json"
out=$(FM_LINEAR_PENDING_ALARM_SECONDS=300 run_poll "$home" "$fixtures") || fail "alarm poll failed"
assert_contains "$out" "UNHANDLED captain inputs" "stale pending event was silent"
assert_contains "$out" "TURN-MARKER MISMATCH BIG-9" "board invariant mismatch was silent"
fixtures="$TMP_ROOT/alarm-empty-fixtures"
make_fixtures "$fixtures" '[]' '[]'
out=$(run_poll "$home" "$fixtures") || fail "retained mismatch poll failed"
assert_contains "$out" "TURN-MARKER MISMATCH BIG-9" "unresolved turn-marker mismatch expired from the incremental page"
fixtures="$TMP_ROOT/alarm-resolved-fixtures"
good_issue=$(issue BIG-9 2026-08-14T12:00:00Z firstmate-id shared-name '[]' 'Approve Deliverable' captain-id renamed-captain)
issues=$(jq -nc --argjson i "$good_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "canonical mismatch resolution poll failed"
assert_not_contains "$out" "TURN-MARKER MISMATCH BIG-9" "canonical assignment did not resolve the retained mismatch"
pass "stale pending events and canonical turn-marker drift wake loudly"

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
unknown_issue=$(issue BIG-10 2026-08-14T11:59:00Z captain-id shared-name '[]' QA)
other_unknown_issue=$(issue BIG-11 2026-08-14T12:00:01Z captain-id shared-name '[]' QA)
issues=$(jq -nc --argjson a "$unknown_issue" --argjson b "$other_unknown_issue" '[$a,$b]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "issue-scoped unknown-status poll failed"
assert_not_contains "$out" "UNKNOWN STATUS QA (BIG-10)" "BIG-11 invalidated BIG-10's exact acknowledgment"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-11)" "BIG-10's acknowledgment silenced BIG-11"
fixtures="$TMP_ROOT/unknown-status-unlogged-reentry-fixtures"
unknown_issue=$(issue BIG-10 2026-08-14T12:00:05Z captain-id shared-name '[]' QA)
issues=$(jq -nc --argjson i "$unknown_issue" '[$i]')
make_fixtures "$fixtures" '[]' "$issues"
out=$(run_poll "$home" "$fixtures") || fail "unlogged unknown-status reentry poll failed"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-10)" \
  "acknowledgment survived an updated snapshot whose status continuity was unprovable"
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
unknown_status_home=$home
home=$(make_home unknown-status-old-history)
fixtures="$TMP_ROOT/unknown-status-old-history-a"
old_entry=$(history old-qa-entry 2026-08-14T11:58:00Z captain-id shared-name Backlog QA)
old_issue=$(issue BIG-50 2026-08-14T11:59:00Z captain-id shared-name \
  "$(jq -nc --argjson h "$old_entry" '[$h]')" QA)
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$old_issue" '[$i]')"
run_poll "$home" "$fixtures" >/dev/null || fail "old-history unknown baseline failed"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLL" acknowledge-unknown-status BIG-50 QA \
  >/dev/null || fail "old-history unknown acknowledgment failed"
fixtures="$TMP_ROOT/unknown-status-old-history-b"
reentered=$(printf '%s' "$old_issue" | jq '.updatedAt="2026-08-14T12:00:05Z"')
make_fixtures "$fixtures" '[]' "$(jq -nc --argjson i "$reentered" '[$i]')"
out=$(run_poll "$home" "$fixtures") || fail "old-history unknown reentry poll failed"
assert_contains "$out" "UNKNOWN STATUS QA (BIG-50)" \
  "an acknowledged historical entry suppressed a newer snapshot reentry"
grep -Fq $'BIG-50\tQA\tsnapshot:2026-08-14T12:00:05.000000000Z' \
  "$home/state/.linear-unknown-status.tsv" \
  || fail "unproven unknown-status continuity reused the old history occurrence"
pass "unknown-status reentry rejects history before the prior issue head"
home=$unknown_status_home
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

# Migration contract: configured credentials arm the reviewed replacement on
# the next bootstrap without touching a real operational home in this test.
home=$(make_home bootstrap)
for legacy in .linear-absorb .linear-state-snapshot .linear-inbox-seen .linear-comment-cursor; do
  printf 'legacy\n' > "$home/state/$legacy"
done
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
printf 'LINEAR_API_KEY=test-key\nLINEAR_FIRSTMATE_ID=firstmate-id\nLINEAR_CAPTAIN_ID=captain-id\n' \
  > "$home/.env"
out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
[ -x "$home/state/fm-linear-inbox.check.sh" ] || fail "configured credentials did not preserve the armed replacement"
[ -f "$home/state/fm-linear-inbox.check-trust" ] || fail "configured credentials lost watcher trust"
[ -f "$home/config/x-mode.env" ] || fail "configured credentials lost the connector cadence"
pass "configured credentials arm and preserve the reviewed replacement"

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
