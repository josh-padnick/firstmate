#!/usr/bin/env bash
# Perform every state-carrying Firstmate write to Linear through one journaled door.
# Usage:
#   fm-linear-act.sh handoff-to-captain <BIG-n> --status <name> --comment-file <path> [--parent <id>]
#   fm-linear-act.sh take-from-captain <BIG-n> --status <name> --comment-file <path> [--parent <id>]
#   fm-linear-act.sh reply <BIG-n> --comment-file <path> --parent <id>
#   fm-linear-act.sh escalate <BIG-n> --to firstmate-decision|captain-decision --comment-file <path>
#   fm-linear-act.sh repair <BIG-n>
#   fm-linear-act.sh resume
#
# Intent is journaled before mutation.
# State and assignee move in one issueUpdate, comments use client-generated IDs,
# and the final state is read back before a journal is marked done.
#
# Set FM_LINEAR_FIXTURE_DIR to consume ordered canned GraphQL responses instead
# of HTTP, and FM_LINEAR_FIXTURE_LOG to record fixture-backed operations.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTBOX="$STATE/linear-outbox"
LOCK="$STATE/.linear-act-lock"
SELF_NAME=${FM_LINEAR_SELF_NAME:-josh.padnickfirstmate}
CAPTAIN_NAME=${FM_LINEAR_CAPTAIN_NAME:-josh.padnick}

# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

FM_LINEAR_FIXTURE_INDEX=0
FM_LINEAR_FIXTURE_NEXT=
FM_LINEAR_API_ERROR=
FM_LINEAR_KEY=
FM_LINEAR_FIRSTMATE_ID=
FM_LINEAR_CAPTAIN_ID=
FM_LINEAR_IDENTITY_ERROR=
TMP_ROOT=
LOCK_HELD=0

cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf -- "$TMP_ROOT"
  [ "$LOCK_HELD" -eq 0 ] || fm_linear_lock_release "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

die() {
  printf 'linear: WRITE FAILED: %s\n' "$*" >&2
  exit 1
}

require_issue() {
  case "$1" in BIG-[0-9]*) ;; *) die "invalid BIG issue identifier: $1" ;; esac
}

attachment_lint() {  # <body-file>
  local file=$1 line url
  while IFS= read -r line; do
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      case "$line" in
        *"!["*"($url)"*) ;;
        *) die "bare uploads.linear.app URL violates the native-documents rule" ;;
      esac
    done < <(printf '%s\n' "$line" | grep -Eo 'https://uploads\.linear\.app[^)[:space:]]*' || true)
  done < "$file"
}

api() {  # <operation> <payload-file> <response-file>
  fm_linear_api_call "$1" "$2" "$3" || die "${FM_LINEAR_API_ERROR:-$1 failed}"
}

resolve_issue() {  # <BIG-n> <target-status-or-empty> <target-role-or-empty> <output>
  local issue=$1 status=$2 role=$3 output=$4 payload="$TMP_ROOT/resolve-payload.json" response="$TMP_ROOT/resolve-response.json"
  local query assignee_id viewer_id
  if [ -n "$status" ]; then
    fm_linear_load_identity_ids || die "$FM_LINEAR_IDENTITY_ERROR"
    # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
    query='query($issue:String!){viewer{id} issue(id:$issue){id state{id name} assignee{id displayName} team{states{nodes{id name}}}}}'
  else
    # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
    query='query($issue:String!){issue(id:$issue){id state{id name} assignee{id displayName}}}'
  fi
  jq -n --arg query "$query" --arg issue "$issue" \
    '{query:$query,variables:{issue:$issue}}' > "$payload" || die "cannot build issue lookup"
  api resolve "$payload" "$response"
  jq -e '.data.issue.id != null' "$response" >/dev/null 2>&1 || die "issue not found: $issue"
  if [ -z "$status" ]; then
    jq '.data.issue | {issue_id:.id, current_state:.state.name,
        current_assignee:(.assignee.displayName // "")}' \
      "$response" > "$output" || die "cannot parse issue lookup"
    return 0
  fi
  viewer_id=$(jq -r '.data.viewer.id // empty' "$response")
  [ "$viewer_id" = "$FM_LINEAR_FIRSTMATE_ID" ] \
    || die "LINEAR_FIRSTMATE_ID does not match the authenticated Linear viewer"
  if [ "$role" = captain ]; then assignee_id=$FM_LINEAR_CAPTAIN_ID; else assignee_id=$FM_LINEAR_FIRSTMATE_ID; fi
  jq --arg status "$status" --arg assignee_id "$assignee_id" '
    .data.issue as $issue
    | ($issue.team.states.nodes | map(select(.name == $status)) | .[0]) as $state
    | if $state == null then error("target status not found")
      else {issue_id:$issue.id, current_state:$issue.state.name,
            current_assignee:($issue.assignee.displayName // ""),
            state_id:$state.id, assignee_id:$assignee_id}
      end
  ' "$response" > "$output" 2>/dev/null || die "cannot resolve status or assignee for $issue"
}

create_journal() {  # <issue> <status> <body-file> <parent> <journal-output-var-name>
  local issue=$1 status=$2 body_file=$3 parent=$4 output_var=$5 uuid comment_id role resolved journal_path created body
  uuid=$(fm_linear_uuid) || die "cannot generate journal UUID"
  comment_id=$(fm_linear_uuid) || die "cannot generate comment UUID"
  created=$(fm_linear_iso_from_epoch "${FM_LINEAR_NOW_EPOCH:-$(date +%s)}") || die "cannot timestamp journal"
  role=
  resolved="$TMP_ROOT/resolved-$uuid.json"
  if [ -n "$status" ]; then
    role=$(fm_linear_status_role "$status") || die "unknown state-carrying status: $status"
  fi
  resolve_issue "$issue" "$status" "$role" "$resolved"
  body=$(cat "$body_file") || die "cannot read comment file: $body_file"
  journal_path="$OUTBOX/$uuid.json"
  jq -n --slurpfile resolved "$resolved" --arg id "$uuid" --arg issue "$issue" \
    --arg status "$status" --arg body_file "$body_file" --arg body "$body" \
    --arg parent "$parent" --arg comment_id "$comment_id" --arg created "$created" '
      {version:1, id:$id, issue:$issue, created_at:$created,
       issue_id:$resolved[0].issue_id,
       target_state:(if $status == "" then null else $status end),
       state_id:($resolved[0].state_id // null),
       assignee_id:($resolved[0].assignee_id // null),
       comment_file:$body_file, comment_body:$body, comment_id:$comment_id,
       parent_id:(if $parent == "" then null else $parent end), phase:"journaled"}
    ' | fm_linear_atomic_file "$journal_path" 600 || die "cannot publish write journal"
  printf -v "$output_var" '%s' "$journal_path"
}

update_journal_phase() {  # <journal> <phase>
  local journal=$1 phase=$2 updated="$TMP_ROOT/journal-updated.json"
  jq --arg phase "$phase" '.phase=$phase' "$journal" > "$updated" || die "cannot update write journal"
  fm_linear_atomic_file "$journal" 600 < "$updated" || die "cannot publish write journal phase"
}

test_pause_after_mutation() {
  local control=${FM_LINEAR_TEST_PAUSE_AFTER_MUTATION_DIR:-} attempts=0
  [ -n "$control" ] || return 0
  : > "$control/ready" || die "cannot publish mutation pause signal"
  while [ ! -e "$control/release" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 1000 ] || die "timed out waiting for mutation pause release"
    sleep 0.01
  done
}

apply_state_mutation() {  # <journal>
  local journal=$1 payload="$TMP_ROOT/mutate-payload.json" response="$TMP_ROOT/mutate-response.json" query
  [ "$(jq -r '.target_state // empty' "$journal")" != "" ] || return 0
  [ "$(jq -r '.phase // "journaled"' "$journal")" = journaled ] || return 0
  # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
  query='mutation($issue:String!,$state:String!,$assignee:String!){issueUpdate(id:$issue,input:{stateId:$state,assigneeId:$assignee}){success issue{id state{name} assignee{displayName}}}}'
  jq -n --arg query "$query" \
    --arg issue "$(jq -r '.issue_id' "$journal")" \
    --arg state "$(jq -r '.state_id' "$journal")" \
    --arg assignee "$(jq -r '.assignee_id' "$journal")" \
    '{query:$query,variables:{issue:$issue,state:$state,assignee:$assignee}}' > "$payload" || die "cannot build state mutation"
  api issueUpdate "$payload" "$response"
  jq -e '.data.issueUpdate.success == true' "$response" >/dev/null 2>&1 || die "atomic state and assignee mutation was not accepted"
  update_journal_phase "$journal" mutated
  test_pause_after_mutation
  if [ "${FM_LINEAR_TEST_KILL_AFTER_MUTATION:-0}" = 1 ]; then
    kill -KILL "$$"
  fi
}

post_comment() {  # <journal>
  local journal=$1 phase payload="$TMP_ROOT/comment-payload.json" response="$TMP_ROOT/comment-response.json" query accepted=0
  phase=$(jq -r '.phase // "journaled"' "$journal")
  [ "$phase" != verified ] || return 0
  if [ "$(jq -r '.target_state // empty' "$journal")" != "" ] && [ "$phase" = journaled ]; then
    return 0
  fi
  # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
  query='mutation($id:String!,$issue:String!,$body:String!,$parent:String){commentCreate(input:{id:$id,issueId:$issue,body:$body,parentId:$parent}){success comment{id}}}'
  jq -n --arg query "$query" \
    --arg id "$(jq -r '.comment_id' "$journal")" \
    --arg issue "$(jq -r '.issue_id' "$journal")" \
    --arg body "$(jq -r '.comment_body' "$journal")" \
    --arg parent "$(jq -r '.parent_id // empty' "$journal")" '
      {query:$query,variables:{id:$id,issue:$issue,body:$body,
       parent:(if $parent == "" then null else $parent end)}}
    ' > "$payload" || die "cannot build comment mutation"
  if ! fm_linear_api_call commentCreate "$payload" "$response"; then
    case "$FM_LINEAR_API_ERROR" in
      *already*exist*|*duplicate*|*taken*) ;;
      *) die "${FM_LINEAR_API_ERROR:-comment creation failed}" ;;
    esac
  elif ! jq -e '.data.commentCreate.success == true' "$response" >/dev/null 2>&1; then
    die "comment mutation was not accepted"
  else
    accepted=1
  fi
  if [ "$accepted" -eq 1 ] && [ "${FM_LINEAR_TEST_KILL_AFTER_COMMENT_ACCEPTED:-0}" = 1 ]; then
    kill -KILL "$$"
  fi
  update_journal_phase "$journal" commented
}

verify_journal() {  # <journal>
  local journal=$1 payload="$TMP_ROOT/verify-payload.json" response="$TMP_ROOT/verify-response.json" query
  local target_state expected_assignee_id actual_state actual_assignee_id actual_assignee comment_id comment_seen completed
  target_state=$(jq -r '.target_state // empty' "$journal")
  expected_assignee_id=$(jq -r '.assignee_id // empty' "$journal")
  comment_id=$(jq -r '.comment_id' "$journal")
  # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
  query='query($issue:String!,$comment:String!){issue(id:$issue){state{name} assignee{id displayName}} comment(id:$comment){id}}'
  jq -n --arg query "$query" --arg issue "$(jq -r '.issue_id' "$journal")" --arg comment "$comment_id" \
    '{query:$query,variables:{issue:$issue,comment:$comment}}' > "$payload" || die "cannot build read-back query"
  api verify "$payload" "$response"
  actual_state=$(jq -r '.data.issue.state.name // empty' "$response")
  actual_assignee_id=$(jq -r '.data.issue.assignee.id // empty' "$response")
  actual_assignee=$(jq -r '.data.issue.assignee.displayName // empty' "$response")
  comment_seen=$(jq -r '.data.comment.id // empty' "$response")
  [ "$comment_seen" = "$comment_id" ] || die "read-back did not find comment $comment_id"
  if [ -n "$target_state" ]; then
    [ "$actual_state" = "$target_state" ] && [ "$actual_assignee_id" = "$expected_assignee_id" ] \
      || die "read-back mismatch for $(jq -r '.issue' "$journal"): state=$actual_state assignee=$actual_assignee ($actual_assignee_id)"
  fi
  update_journal_phase "$journal" verified
  completed=${journal%.json}.done
  mv -f -- "$journal" "$completed" || die "cannot complete write journal"
  printf 'linear: write verified for %s\n' "$(jq -r '.issue' "$completed")"
}

resume_journal() {  # <journal>
  local journal=$1
  [ -f "$journal" ] && [ ! -L "$journal" ] || die "unsafe write journal: $journal"
  apply_state_mutation "$journal"
  post_comment "$journal"
  verify_journal "$journal"
}

resume_all() {
  local journal found=0
  for journal in "$OUTBOX"/*.json; do
    [ -f "$journal" ] || continue
    found=1
    resume_journal "$journal"
  done
  [ "$found" -eq 1 ] || printf 'linear: no unfinished writes\n'
}

make_repair_comment() {  # <issue> <status> <assignee> <output>
  printf 'Repaired the turn marker for %s: %s belongs to %s under the board contract.\n' \
    "$1" "$2" "$3" > "$4"
}

parse_write_args() {
  ISSUE=
  STATUS=
  COMMENT_FILE=
  PARENT=
  TARGET=
  [ "$#" -ge 1 ] || die "issue identifier is required"
  ISSUE=$1
  shift
  require_issue "$ISSUE"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) [ "$#" -ge 2 ] || die "--status needs a value"; STATUS=$2; shift 2 ;;
      --comment-file) [ "$#" -ge 2 ] || die "--comment-file needs a value"; COMMENT_FILE=$2; shift 2 ;;
      --parent) [ "$#" -ge 2 ] || die "--parent needs a value"; PARENT=$2; shift 2 ;;
      --to) [ "$#" -ge 2 ] || die "--to needs a value"; TARGET=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

main() {
  local command=${1:-} journal role resolved status assignee lock_status
  [ -n "$command" ] || die "a subcommand is required"
  shift
  command -v jq >/dev/null 2>&1 || die "missing jq"
  fm_linear_private_dir "$STATE" || die "state directory unavailable"
  fm_linear_private_dir "$OUTBOX" || die "outbox unavailable"
  fm_linear_lock_acquire "$LOCK"
  lock_status=$?
  case "$lock_status" in
    0) LOCK_HELD=1 ;;
    1) die "another outbound Linear writer is active" ;;
    *) die "outbound write lock state is unsafe" ;;
  esac
  fm_linear_load_key || die "missing LINEAR_API_KEY in $FM_HOME/.env"
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-act.XXXXXX") || die "cannot create write workspace"

  case "$command" in
    resume)
      [ "$#" -eq 0 ] || die "resume takes no arguments"
      resume_all
      ;;
    repair)
      [ "$#" -eq 1 ] || die "repair requires one issue"
      ISSUE=$1
      require_issue "$ISSUE"
      resolved="$TMP_ROOT/repair-resolved.json"
      resolve_issue "$ISSUE" "" "" "$resolved"
      status=$(jq -r '.current_state // empty' "$resolved")
      role=$(fm_linear_status_role "$status") || die "cannot repair unknown status: $status"
      if [ "$role" = captain ]; then assignee=$CAPTAIN_NAME; else assignee=$SELF_NAME; fi
      COMMENT_FILE="$TMP_ROOT/repair-comment.md"
      make_repair_comment "$ISSUE" "$status" "$assignee" "$COMMENT_FILE"
      attachment_lint "$COMMENT_FILE"
      create_journal "$ISSUE" "$status" "$COMMENT_FILE" "" journal
      resume_journal "$journal"
      ;;
    handoff-to-captain|take-from-captain|reply|escalate)
      parse_write_args "$@"
      [ -n "$COMMENT_FILE" ] && [ -f "$COMMENT_FILE" ] || die "a readable --comment-file is required"
      attachment_lint "$COMMENT_FILE"
      case "$command" in
        handoff-to-captain)
          [ -n "$STATUS" ] || die "handoff-to-captain requires --status"
          [ "$(fm_linear_status_role "$STATUS" 2>/dev/null || true)" = captain ] \
            || die "handoff status does not belong to the captain"
          ;;
        take-from-captain)
          [ -n "$STATUS" ] || die "take-from-captain requires --status"
          [ "$(fm_linear_status_role "$STATUS" 2>/dev/null || true)" = firstmate ] \
            || die "take status does not belong to firstmate"
          ;;
        reply)
          [ -n "$PARENT" ] || die "reply requires --parent"
          [ -z "$STATUS" ] || die "reply does not accept --status"
          ;;
        escalate)
          case "$TARGET" in
            firstmate-decision) STATUS='Needs Firstmate Decision' ;;
            captain-decision) STATUS='Needs Decision' ;;
            *) die "escalate --to must name firstmate-decision or captain-decision" ;;
          esac
          ;;
      esac
      create_journal "$ISSUE" "$STATUS" "$COMMENT_FILE" "$PARENT" journal
      resume_journal "$journal"
      ;;
    *) die "unknown subcommand: $command" ;;
  esac
}

main "$@"
