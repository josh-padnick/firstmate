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
TMP_ROOT=$(fm_test_tmproot fm-linear-act)
NOW=$(jq -nr '"2026-08-14T12:00:00Z" | fromdateiso8601')

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf 'LINEAR_API_KEY=test-key\n' > "$home/.env"
  printf 'READY FOR YOUR REVIEW\n' > "$home/comment.md"
  chmod 0600 "$home/.env"
  printf '%s\n' "$home"
}

resolve_fixture() {  # <file> [current-status] [current-assignee]
  jq -n --arg status "${2:-Building}" --arg assignee "${3:-josh.padnickfirstmate}" '
    {data:{issue:{id:"issue-1",state:{id:"building",name:$status},
      assignee:{id:"firstmate-id",displayName:$assignee},team:{
        states:{nodes:[{id:"approve",name:"Approve Deliverable"},{id:"building",name:"Building"},
                       {id:"needs-firstmate",name:"Needs Firstmate Decision"},{id:"needs-captain",name:"Needs Decision"}]},
        members:{nodes:[{id:"captain-id",displayName:"josh.padnick"},
                        {id:"firstmate-id",displayName:"josh.padnickfirstmate"}]}}}}}
  ' > "$1"
}

mutation_fixture() {  # <file>
  jq -n '{data:{issueUpdate:{success:true,issue:{id:"issue-1",state:{name:"Approve Deliverable"},assignee:{displayName:"josh.padnick"}}}}}' > "$1"
}

comment_fixture() {  # <file>
  jq -n '{data:{commentCreate:{success:true,comment:{id:"__COMMENT_ID__"}}}}' > "$1"
}

verify_fixture() {  # <file> <status> <assignee>
  jq -n --arg status "$2" --arg assignee "$3" '
    {data:{issue:{state:{name:$status},assignee:{displayName:$assignee}},comment:{id:"__COMMENT_ID__"}}}
  ' > "$1"
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
mutation_fixture "$fixtures/02-mutate.json"
comment_fixture "$fixtures/03-comment.json"
verify_fixture "$fixtures/04-verify.json" Building josh.padnickfirstmate
out=$(run_act "$home" "$fixtures" handoff-to-captain BIG-1 \
  --status 'Approve Deliverable' --comment-file "$home/comment.md" 2>&1 || true)
assert_contains "$out" "read-back mismatch" "stale board read-back did not fail loudly"
[ "$(find "$home/state/linear-outbox" -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  || fail "read-back mismatch did not retain the unfinished journal"
pass "write success requires matching state, assignee, and comment read-back"

# T10 crash contract: mutation and assignee are sent in one request, a SIGKILL
# leaves one journal, and resume posts exactly one stable client comment ID.
home=$(make_home resume)
fixtures="$TMP_ROOT/kill-fixtures"
mkdir -p "$fixtures"
resolve_fixture "$fixtures/01-resolve.json"
mutation_fixture "$fixtures/02-mutate.json"
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
