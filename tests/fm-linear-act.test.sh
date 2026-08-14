#!/usr/bin/env bash
# Regression tests for the journaled Linear outbound write door.
#
# The suite drives the executable through fixture-backed GraphQL operations and
# proves atomic field mutation, read-back refusal, kill-safe resume, stable
# client comment IDs, and upload-link linting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACT="$ROOT/bin/fm-linear-act.sh"
POLL="$ROOT/bin/fm-linear-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear-act)
NOW=1786708800

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf 'LINEAR_API_KEY=test-key\nLINEAR_FIRSTMATE_ID=firstmate-id\nLINEAR_CAPTAIN_ID=captain-id\n' \
    > "$home/.env"
  printf 'READY FOR YOUR REVIEW\n' > "$home/comment.md"
  chmod 0600 "$home/.env"
  printf '%s\n' "$home"
}

resolve_fixture() {  # <file> [current-status] [current-assignee] [current-assignee-id]
  jq -n --arg status "${2:-Building}" --arg assignee "${3:-josh.padnickfirstmate}" \
    --arg assignee_id "${4:-firstmate-id}" '
    {data:{viewer:{id:"firstmate-id"},issue:{id:"issue-1",
      state:{id:(if $status == "Approve Deliverable" then "approve" else "building" end),name:$status},
      assignee:{id:$assignee_id,displayName:$assignee},team:{
        states:{nodes:[{id:"approve",name:"Approve Deliverable"},{id:"building",name:"Building"},
                       {id:"needs-firstmate",name:"Needs Firstmate Decision"},{id:"needs-captain",name:"Needs Decision"}]},
        members:{nodes:[{id:"wrong-captain-id",displayName:"josh.padnick"},
                        {id:"captain-id",displayName:"josh.padnick"},
                        {id:"wrong-firstmate-id",displayName:"josh.padnickfirstmate"},
                        {id:"firstmate-id",displayName:"renamed-firstmate"}]}}}}}
  ' > "$1"
}

mutation_read_fixture() {  # <file> <state-id> <state-name> <assignee-id> <assignee-name>
  jq -n --arg state_id "$2" --arg state "$3" --arg assignee_id "$4" --arg assignee "$5" '
    {data:{issue:{state:{id:$state_id,name:$state},assignee:{id:$assignee_id,displayName:$assignee}}}}
  ' > "$1"
}

mutation_fixture() {  # <file>
  jq -n '{data:{issueUpdate:{success:true,issue:{id:"issue-1",state:{name:"Approve Deliverable"},assignee:{displayName:"josh.padnick"}}}}}' > "$1"
}

comment_fixture() {  # <file>
  jq -n '{data:{commentCreate:{success:true,comment:{id:"__COMMENT_ID__"}}}}' > "$1"
}

verify_fixture() {  # <file> <status> <assignee> [assignee-id]
  jq -n --arg status "$2" --arg assignee "$3" --arg assignee_id "${4:-}" '
    {data:{issue:{state:{name:$status},assignee:{
      id:(if $assignee_id != "" then $assignee_id
          elif $assignee == "josh.padnick" then "captain-id" else "firstmate-id" end),
      displayName:$assignee}},comment:{id:"__COMMENT_ID__"}}}
  ' > "$1"
}

comment_read_fixture() {  # <file> [present]
  if [ "${2:-true}" = true ]; then
    jq -n '{data:{comment:{id:"__COMMENT_ID__"}}}' > "$1"
  else
    jq -n '{data:{comment:null}}' > "$1"
  fi
}

run_act() {  # <home> <fixtures> <args...>
  local home=$1 fixtures=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
    FM_LINEAR_NOW_EPOCH="$NOW" "$ACT" "$@"
}

# T10 read-back mismatch: a successful mutation is not reported as success when
# the board still shows the old state.
home=$(make_home mismatch)
fixtures="$TMP_ROOT/mismatch-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
comment_fixture "$fixtures/04-comment.json"
verify_fixture "$fixtures/05-verify.json" Building josh.padnickfirstmate
out=$(run_act "$home" "$fixtures" handoff-to-captain BIG-1 \
  --status 'Approve Deliverable' --comment-file "$home/comment.md" 2>&1 || true)
assert_contains "$out" "read-back mismatch" "stale board read-back did not fail loudly"
[ "$(find "$home/state/linear-outbox" -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  || fail "read-back mismatch did not retain the unfinished journal"
pass "write success requires matching state, assignee, and comment read-back"

home=$(make_home assignee-id-mismatch)
fixtures="$TMP_ROOT/assignee-id-mismatch-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
comment_fixture "$fixtures/04-comment.json"
verify_fixture "$fixtures/05-verify.json" 'Approve Deliverable' josh.padnick wrong-captain-id
out=$(run_act "$home" "$fixtures" handoff-to-captain BIG-1 \
  --status 'Approve Deliverable' --comment-file "$home/comment.md" 2>&1 || true)
assert_contains "$out" "read-back mismatch" "same-name wrong-ID assignee passed read-back"
[ "$(find "$home/state/linear-outbox" -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  || fail "assignee ID mismatch did not retain the unfinished journal"
pass "write read-back verifies stable assignee identity"

# T10 crash contract: mutation and assignee are sent in one request, a SIGKILL
# leaves one journal, and resume posts exactly one stable client comment ID.
home=$(make_home resume)
fixtures="$TMP_ROOT/kill-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
log="$home/kill.log"
(
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
    FM_LINEAR_FIXTURE_LOG="$log" FM_LINEAR_NOW_EPOCH="$NOW" \
    FM_LINEAR_TEST_KILL_AFTER_MUTATION=1 "$ACT" handoff-to-captain BIG-1 \
      --status 'Approve Deliverable' --comment-file "$home/comment.md"
) >/dev/null 2>&1 || true
journal=$(find "$home/state/linear-outbox" -name '*.json' | head -n 1)
[ -n "$journal" ] || fail "SIGKILL did not leave a resumable journal"
[ "$(jq -r '.phase' "$journal")" = mutated ] || fail "journal did not durably record the atomic mutation"
mutate_payload=$(awk -F '\t' '$1=="issueUpdate"{print $2}' "$log")
printf '%s' "$mutate_payload" | jq -e '.variables.state != "" and .variables.assignee != ""' >/dev/null \
  || fail "state and assignee were not present in one mutation request"
printf '%s' "$mutate_payload" | jq -e '.variables.assignee == "captain-id"' >/dev/null \
  || fail "captain handoff did not use the configured stable captain ID"
printf '%s' "$mutate_payload" | jq -e '.variables.issue == "issue-1"' >/dev/null \
  || fail "state mutation did not use the resolved Linear issue UUID"

fixtures="$TMP_ROOT/resume-fixtures"
mkdir -p "$fixtures"
comment_fixture "$fixtures/01-comment.json"
verify_fixture "$fixtures/02-verify.json" 'Approve Deliverable' josh.padnick
resume_log="$home/resume.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_FIXTURE_LOG="$resume_log" FM_LINEAR_NOW_EPOCH="$NOW" "$ACT" resume >/dev/null \
  || fail "resume did not complete the interrupted write"
[ "$(find "$home/state/linear-outbox" -name '*.done' | wc -l | tr -d ' ')" = 1 ] \
  || fail "resume did not complete exactly one journal"
[ "$(awk -F '\t' '$1=="commentCreate"{n++} END{print n+0}' "$resume_log")" = 1 ] \
  || fail "resume posted more than one comment"
posted_id=$(awk -F '\t' '$1=="commentCreate"{print $2}' "$resume_log" | jq -r '.variables.id')
[ "$posted_id" = "$(jq -r '.comment_id' "$home/state/linear-outbox"/*.done)" ] \
  || fail "resume did not reuse the journaled client comment ID"
awk -F '\t' '$1=="commentCreate"{print $2}' "$resume_log" | jq -e '.variables.issue == "issue-1"' >/dev/null \
  || fail "comment mutation did not use the resolved Linear issue UUID"
pass "a killed state-carrying write resumes without half state or duplicate comments"

home=$(make_home accepted-mutation)
fixtures="$TMP_ROOT/accepted-mutation-kill-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
(
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
    FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_TEST_KILL_AFTER_MUTATION_ACCEPTED=1 \
    "$ACT" handoff-to-captain BIG-1 --status 'Approve Deliverable' \
      --comment-file "$home/comment.md"
) >/dev/null 2>&1 || true
journal=$(find "$home/state/linear-outbox" -name '*.json' | head -n 1)
[ "$(jq -r '.phase' "$journal")" = journaled ] \
  || fail "accepted mutation kill did not preserve the pre-publication journal phase"
fixtures="$TMP_ROOT/accepted-mutation-resume-fixtures"
mkdir -p "$fixtures"
mutation_read_fixture "$fixtures/01-read.json" approve 'Approve Deliverable' captain-id josh.padnick
comment_fixture "$fixtures/02-comment.json"
verify_fixture "$fixtures/03-verify.json" 'Approve Deliverable' josh.padnick
resume_log="$home/accepted-mutation-resume.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_FIXTURE_LOG="$resume_log" FM_LINEAR_NOW_EPOCH="$NOW" "$ACT" resume >/dev/null \
  || fail "accepted mutation did not settle by read-back"
[ "$(awk -F '\t' '$1=="issueUpdate"{n++} END{print n+0}' "$resume_log")" = 0 ] \
  || fail "accepted mutation was replayed after exact target read-back"
pass "accepted pre-phase state mutations settle without replay"

home=$(make_home mutation-conflict)
fixtures="$TMP_ROOT/mutation-conflict-kill-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
(
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
    FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_TEST_KILL_AFTER_MUTATION_ACCEPTED=1 \
    "$ACT" handoff-to-captain BIG-1 --status 'Approve Deliverable' \
      --comment-file "$home/comment.md"
) >/dev/null 2>&1 || true
fixtures="$TMP_ROOT/mutation-conflict-resume-fixtures"
mkdir -p "$fixtures"
mutation_read_fixture "$fixtures/01-read.json" needs-captain 'Needs Decision' captain-id josh.padnick
resume_log="$home/mutation-conflict-resume.log"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_FIXTURE_LOG="$resume_log" FM_LINEAR_NOW_EPOCH="$NOW" "$ACT" resume 2>&1 || true)
assert_contains "$out" "state mutation conflict" "captain's newer board state was not surfaced as a replay conflict"
[ "$(awk -F '\t' '$1=="issueUpdate"{n++} END{print n+0}' "$resume_log")" = 0 ] \
  || fail "recovery overwrote the captain's divergent board state"
pass "state replay refuses to overwrite a divergent captain change"

home=$(make_home stable-firstmate-id)
fixtures="$TMP_ROOT/stable-firstmate-id-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json" 'Approve Deliverable' josh.padnick captain-id
mutation_read_fixture "$fixtures/02-read.json" approve 'Approve Deliverable' captain-id josh.padnick
mutation_fixture "$fixtures/03-mutate.json"
comment_fixture "$fixtures/04-comment.json"
verify_fixture "$fixtures/05-verify.json" Building renamed-firstmate firstmate-id
identity_log="$home/identity.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_FIXTURE_LOG="$identity_log" FM_LINEAR_NOW_EPOCH="$NOW" \
  "$ACT" take-from-captain BIG-1 --status Building --comment-file "$home/comment.md" >/dev/null \
  || fail "stable Firstmate identity handoff failed"
awk -F '\t' '$1=="issueUpdate"{print $2}' "$identity_log" \
  | jq -e '.variables.assignee == "firstmate-id"' >/dev/null \
  || fail "Firstmate handoff resolved through a display-name collision"
pass "state transitions resolve assignees from canonical stable IDs"

home=$(make_home missing-captain-id)
printf 'LINEAR_API_KEY=test-key\nLINEAR_FIRSTMATE_ID=firstmate-id\n' > "$home/.env"
out=$(run_act "$home" "$TMP_ROOT/no-identity-fixtures" handoff-to-captain BIG-1 \
  --status 'Approve Deliverable' --comment-file "$home/comment.md" 2>&1 || true)
assert_contains "$out" "missing LINEAR_CAPTAIN_ID" "missing canonical captain ID did not fail loudly"
[ "$(find "$home/state/linear-outbox" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  || fail "missing canonical captain ID created a write journal"
pass "writes refuse to journal without canonical identity IDs"

home=$(make_home reply-without-assignee-ids)
printf 'LINEAR_API_KEY=test-key\n' > "$home/.env"
fixtures="$TMP_ROOT/reply-without-assignee-ids-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
comment_fixture "$fixtures/02-comment.json"
verify_fixture "$fixtures/03-verify.json" Building josh.padnickfirstmate
run_act "$home" "$fixtures" reply BIG-1 --comment-file "$home/comment.md" --parent parent-1 >/dev/null \
  || fail "comment-only reply required unrelated assignee identities"
[ "$(find "$home/state/linear-outbox" -name '*.done' | wc -l | tr -d ' ')" = 1 ] \
  || fail "comment-only reply did not complete its journal"
pass "comment-only replies do not require assignee identities"

home=$(make_home readiness-marker)
printf 'The deliverable is ready.\n' > "$home/not-ready.md"
out=$(run_act "$home" "$TMP_ROOT/no-readiness-fixtures" handoff-to-captain BIG-1 \
  --status 'Approve Deliverable' --comment-file "$home/not-ready.md" 2>&1 || true)
assert_contains "$out" "must contain READY FOR YOUR REVIEW" \
  "handoff-to-captain accepted a comment without the readiness marker"
[ "$(find "$home/state/linear-outbox" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  || fail "rejected readiness handoff created a journal"
pass "captain handoffs enforce the review-readiness marker"

fake_time_bin="$TMP_ROOT/fake-time-bin"
mkdir -p "$fake_time_bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in *2026-08-14T12:00:00Z*) printf "1786712400\\n"; exit 0 ;; esac' \
  'exec /bin/date "$@"' > "$fake_time_bin/date"
chmod +x "$fake_time_bin/date"
home=$(make_home time-self-check)
out=$(PATH="$fake_time_bin:$PATH" run_act "$home" "$TMP_ROOT/no-time-fixtures" reply BIG-1 \
  --comment-file "$home/comment.md" --parent parent-1 2>&1 || true)
assert_contains "$out" "UTC timestamp conversion self-check failed" \
  "write-door startup accepted the historical plus-one-hour conversion regression"
pass "write-door startup rejects a plus-one-hour UTC conversion regression"

home=$(make_home accepted-comment)
fixtures="$TMP_ROOT/accepted-comment-kill-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
comment_fixture "$fixtures/04-comment.json"
accepted_store="$home/accepted-comment-ids"
accepted_log="$home/accepted-kill.log"
(
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
    FM_LINEAR_FIXTURE_LOG="$accepted_log" FM_LINEAR_FIXTURE_COMMENT_STORE="$accepted_store" \
    FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_TEST_KILL_AFTER_COMMENT_ACCEPTED=1 \
    "$ACT" handoff-to-captain BIG-1 --status 'Approve Deliverable' \
      --comment-file "$home/comment.md"
) >/dev/null 2>&1 || true
journal=$(find "$home/state/linear-outbox" -name '*.json' | head -n 1)
[ -n "$journal" ] || fail "accepted-comment SIGKILL did not leave a resumable journal"
[ "$(jq -r '.phase' "$journal")" = mutated ] \
  || fail "accepted-comment SIGKILL unexpectedly published the commented phase"
[ "$(wc -l < "$accepted_store" | tr -d ' ')" = 1 ] || fail "fixture server did not retain one accepted comment"
fixtures="$TMP_ROOT/accepted-comment-resume-fixtures"
mkdir -p "$fixtures"
comment_fixture "$fixtures/01-comment.json"
comment_read_fixture "$fixtures/02-comment-read.json"
verify_fixture "$fixtures/03-verify.json" 'Approve Deliverable' josh.padnick
retry_log="$home/accepted-retry.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_FIXTURE_LOG="$retry_log" FM_LINEAR_FIXTURE_COMMENT_STORE="$accepted_store" \
  FM_LINEAR_NOW_EPOCH="$NOW" "$ACT" resume >/dev/null \
  || fail "accepted-comment retry did not complete through duplicate-ID recovery"
first_id=$(awk -F '\t' '$1=="commentCreate"{print $2}' "$accepted_log" | jq -r '.variables.id')
retry_id=$(awk -F '\t' '$1=="commentCreate"{print $2}' "$retry_log" | jq -r '.variables.id')
[ "$first_id" = "$retry_id" ] || fail "accepted-comment retry changed the client comment ID"
[ "$(wc -l < "$accepted_store" | tr -d ' ')" = 1 ] || fail "accepted-comment retry created a duplicate server comment"
pass "an accepted comment survives pre-phase SIGKILL without duplication"

home=$(make_home overlap)
printf '{"after":null,"complete":true}\n' > "$home/state/.linear-comment-head-bootstrap.json"
chmod 0600 "$home/state/.linear-comment-head-bootstrap.json"
fixtures="$TMP_ROOT/overlap-act-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_read_fixture "$fixtures/02-read.json" building Building firstmate-id josh.padnickfirstmate
mutation_fixture "$fixtures/03-mutate.json"
comment_fixture "$fixtures/04-comment.json"
verify_fixture "$fixtures/05-verify.json" 'Approve Deliverable' josh.padnick
control="$home/mutation-pause"
mkdir -p "$control"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$fixtures" \
  FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_TEST_PAUSE_AFTER_MUTATION_DIR="$control" \
  "$ACT" handoff-to-captain BIG-1 --status 'Approve Deliverable' \
    --comment-file "$home/comment.md" > "$home/overlap-act.out" 2>&1 &
act_pid=$!
attempts=0
while [ ! -e "$control/ready" ] && kill -0 "$act_pid" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 500 ]; then
    kill "$act_pid" 2>/dev/null || true
    wait "$act_pid" 2>/dev/null || true
    fail "outbound write did not reach the overlap boundary"
  fi
  sleep 0.01
done
[ -e "$control/ready" ] || { wait "$act_pid" 2>/dev/null || true; fail "outbound write failed before overlap"; }
poll_fixtures="$TMP_ROOT/overlap-poll-fixtures"
mkdir -p "$poll_fixtures"
jq -n '
  {data:{viewer:{id:"firstmate-id",displayName:"shared-name"},comments:{
    pageInfo:{hasNextPage:false,endCursor:null},nodes:[
      {id:"captain-during-write",createdAt:"2026-08-14T11:59:01Z",updatedAt:"2026-08-14T11:59:01Z",
       body:"captain input during write",user:{id:"captain-id",displayName:"shared-name"},
       issue:{identifier:"BIG-1",labels:{nodes:[{name:"Firstmate"}]}},parent:null}]}}}
' > "$poll_fixtures/01-comments.json"
jq -n '
  {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{
    identifier:"BIG-1",title:"fixture",description:"",updatedAt:"2026-08-14T11:59:02Z",
    createdAt:"2026-08-01T00:00:00Z",state:{name:"Approve Deliverable"},
    assignee:{id:"captain-id",displayName:"josh.padnick"},
    creator:{id:"firstmate-id",displayName:"shared-name"},labels:{nodes:[]},history:{
      pageInfo:{hasNextPage:false,endCursor:null},nodes:[{
        id:"self-write-history",createdAt:"2026-08-14T11:59:00Z",updatedAt:"2026-08-14T11:59:00Z",changes:null,
        actor:{id:"firstmate-id",displayName:"shared-name"},fromState:{name:"Building"},
        toState:{name:"Approve Deliverable"},fromAssignee:null,
        toAssignee:{id:"captain-id",displayName:"josh.padnick"},updatedDescription:null,
        addedLabels:[],removedLabels:[]}]}}]}}}
' > "$poll_fixtures/02-issues.json"
poll_status=0
poll_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LINEAR_FIXTURE_DIR="$poll_fixtures" \
  FM_LINEAR_NOW_EPOCH="$NOW" FM_LINEAR_PENDING_ALARM_SECONDS=9999 "$POLL") \
  || poll_status=$?
: > "$control/release"
wait "$act_pid" || fail "outbound write did not finish after overlap release"
[ "$poll_status" -eq 0 ] || fail "poll failed while outbound write was paused"
assert_contains "$poll_out" "1 captain input(s)" "captain input was lost during the outbound write"
[ "$(find "$home/state/linear-inbox" -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  || fail "overlapping poll persisted a self-authored event or lost captain input"
[ "$(find "$home/state/linear-outbox" -name '*.done' | wc -l | tr -d ' ')" = 1 ] \
  || fail "overlapping outbound write did not complete"
pass "captain input remains durable during an overlapping Firstmate write"

# T12: bare upload links are rejected before any journal exists, while Markdown
# image embeds pass through the same reply door.
home=$(make_home attachments)
printf 'See https://uploads.linear.app/raw/file.png\n' > "$home/bare.md"
out=$(run_act "$home" "$TMP_ROOT/no-fixtures" reply BIG-1 --comment-file "$home/bare.md" --parent parent-1 2>&1 || true)
assert_contains "$out" "native-documents rule" "bare Linear upload URL was accepted"
[ "$(find "$home/state/linear-outbox" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  || fail "rejected attachment created a write journal"

printf '![screenshot](https://uploads.linear.app/raw/file.png)\n' > "$home/image.md"
fixtures="$TMP_ROOT/image-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
comment_fixture "$fixtures/02-comment.json"
verify_fixture "$fixtures/03-verify.json" Building josh.padnickfirstmate
run_act "$home" "$fixtures" reply BIG-1 --comment-file "$home/image.md" --parent parent-1 >/dev/null \
  || fail "Markdown image embed was incorrectly rejected"
pass "the write door refuses raw upload links and permits image embeds"
