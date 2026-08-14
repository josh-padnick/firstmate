#!/usr/bin/env bash
# Poll Linear into a durable, identity-attributed event ledger.
# Usage:
#   fm-linear-poll.sh
#   fm-linear-poll.sh acknowledge <inbox-filename.json>
#   fm-linear-poll.sh acknowledge-unknown-status <BIG-n> <status>
#
# Captain-authored events are atomically written under state/linear-inbox before
# their content heads are recorded and before either server-timestamp cursor moves.
# Repeated and rewound reads are therefore idempotent, while comment transitions
# compare against the latest body hash and retain a distinct server-timestamp key.
#
# Set FM_LINEAR_FIXTURE_DIR to replace HTTP with lexically ordered canned GraphQL
# responses consumed in request order.
# Set FM_LINEAR_FIXTURE_LOG to record each fixture-backed request for tests.
# Set FM_LINEAR_POLL_DEADLINE_SECONDS below 25 to shorten the complete poll bound.
# Set FM_LINEAR_TIMING=1 to print phase timestamps to stderr for diagnostics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CURSOR_FILE="$STATE/.linear-cursor"
BOOTSTRAP_HORIZON_FILE="$STATE/.linear-bootstrap-horizon"
COMMENT_HEADS_FILE="$STATE/.linear-comment-heads.tsv"
COMMENT_HEAD_BOOTSTRAP_FILE="$STATE/.linear-comment-head-bootstrap.json"
COMMENT_ROOTS_FILE="$STATE/.linear-comment-roots.tsv"
THREAD_ROOT_SCAN_DIR="$STATE/.linear-thread-root-scans"
THREAD_DESCENDANT_SCAN_DIR="$STATE/.linear-thread-descendant-scans"
HISTORY_HEADS_FILE="$STATE/.linear-history-heads.tsv"
THREAD_PARTICIPATION_FILE="$STATE/.linear-thread-participation.tsv"
ISSUE_HEADS_FILE="$STATE/.linear-issue-heads.json"
HISTORY_SCAN_DIR="$STATE/.linear-history-scans"
HEALTH_FILE="$STATE/.linear-poll-health"
ERROR_FILE="$STATE/.linear-poll-error"
UNKNOWN_FILE="$STATE/.linear-unknown-status.tsv"
UNKNOWN_ACK_FILE="$STATE/.linear-unknown-status-acks.tsv"
TURN_MISMATCH_FILE="$STATE/.linear-turn-marker-mismatches.json"
INBOX="$STATE/linear-inbox"
OUTBOX="$STATE/linear-outbox"
LOCK="$STATE/.linear-poll-lock"
FM_LINEAR_FIXTURE_INDEX=0
FM_LINEAR_API_ERROR=
FM_LINEAR_KEY=
TMP_ROOT=
LOCK_HELD=0
NEW_EVENTS=0
NEW_OBSERVATIONS=0
COMMENT_SCAN_PENDING=0
NEW_ISSUES=
NEW_OBSERVATION_ISSUES=
SELF_NAME=${FM_LINEAR_SELF_NAME:-josh.padnickfirstmate}
SELF_MENTION=${FM_LINEAR_SELF_MENTION:-@josh.padnickfirstmate}
SELF_ID=${FM_LINEAR_SELF_ID:-}
CAPTAIN_NAME=${FM_LINEAR_CAPTAIN_NAME:-josh.padnick}
FM_LINEAR_FIRSTMATE_ID=
FM_LINEAR_CAPTAIN_ID=
FM_LINEAR_IDENTITY_ERROR=

cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf -- "$TMP_ROOT"
  [ "$LOCK_HELD" -eq 0 ] || fm_linear_lock_release "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

health_fail_count() {
  sed -n 's/^fail_count=//p' "$HEALTH_FILE" 2>/dev/null | tail -n 1
}

record_failure() {  # <message>
  local message=$1 count prior
  prior=$(health_fail_count)
  case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  count=$((prior + 1))
  {
    printf 'ok_at=%s\n' "$(sed -n 's/^ok_at=//p' "$HEALTH_FILE" 2>/dev/null | tail -n 1)"
    printf 'fail_count=%s\n' "$count"
    printf 'last_error=%s\n' "$(printf '%s' "$message" | tr '\r\n' '  ')"
    printf 'lag_seconds=%s\n' "$(sed -n 's/^lag_seconds=//p' "$HEALTH_FILE" 2>/dev/null | tail -n 1)"
  } | fm_linear_atomic_file "$HEALTH_FILE" 600 || {
    printf 'linear: POLL STATE FAILURE: cannot persist failure health\n'
    return 0
  }
  printf '%s\n' "$message" | fm_linear_atomic_file "$ERROR_FILE" 600 2>/dev/null || true
  printf 'linear: POLL FAILING (%sx): %s\n' "$count" "$message"
}

record_success() {  # <server-timestamp>
  local timestamp=$1 epoch lag=unknown
  epoch=$(fm_linear_epoch "$timestamp" 2>/dev/null || true)
  case "$epoch" in
    ''|*[!0-9]*) ;;
    *) lag=$((${FM_LINEAR_NOW_EPOCH:-$(date +%s)} - epoch)); [ "$lag" -ge 0 ] || lag=0 ;;
  esac
  {
    printf 'ok_at=%s\n' "${timestamp:-none}"
    printf 'fail_count=0\n'
    printf 'last_error=\n'
    printf 'lag_seconds=%s\n' "$lag"
  } | fm_linear_atomic_file "$HEALTH_FILE" 600 || return 1
  rm -f -- "$ERROR_FILE" 2>/dev/null || true
}

cursor_get() {  # <field>
  sed -n "s/^$1=//p" "$CURSOR_FILE" 2>/dev/null | tail -n 1
}

comment_head_current() {  # <comment-id> <body-hash> <edited-at>
  local id=$1 hash=$2 edited=$3
  awk -F '\t' -v id="$id" -v hash="$hash" -v edited="$edited" \
    '$1 == id && $2 == hash && ($3 == edited || (NF == 3 && edited == "")) { found=1 }
     END { exit !found }' \
    "$COMMENT_HEADS_FILE" 2>/dev/null
}

comment_head_set() {  # <comment-id> <body-hash> <edited-at> <observed-at>
  local id=$1 hash=$2 edited=$3 observed=$4 next="$TMP_ROOT/comment-heads-next.tsv"
  if [ -e "$COMMENT_HEADS_FILE" ]; then
    [ -f "$COMMENT_HEADS_FILE" ] && [ ! -L "$COMMENT_HEADS_FILE" ] || return 1
    awk -F '\t' -v id="$id" '$1 != id' "$COMMENT_HEADS_FILE" > "$next" || return 1
  else
    : > "$next"
  fi
  printf '%s\t%s\t%s\t%s\n' "$id" "$hash" "$edited" "$observed" >> "$next" || return 1
  fm_linear_atomic_file "$COMMENT_HEADS_FILE" 600 < "$next"
}

comment_head_seed() {  # <comment-id> <body-hash> <edited-at> <observed-at>
  local id=$1
  if awk -F '\t' -v id="$id" '$1 == id { found=1 } END { exit !found }' \
    "$COMMENT_HEADS_FILE" 2>/dev/null; then
    return 0
  fi
  comment_head_set "$@"
}

comment_hash_known() {  # <comment-id>
  awk -F '\t' -v id="$1" '$1 == id { found=1 } END { exit !found }' \
    "$COMMENT_HEADS_FILE" 2>/dev/null
}

history_hash_current() {  # <history-id> <content-hash>
  awk -F '\t' -v id="$1" -v hash="$2" \
    '$1 == id && $2 == hash { found=1 } END { exit !found }' \
    "$HISTORY_HEADS_FILE" 2>/dev/null
}

history_hash_set() {  # <history-id> <content-hash> <updated-at>
  local id=$1 hash=$2 updated=$3 next="$TMP_ROOT/history-heads-next.tsv"
  if [ -e "$HISTORY_HEADS_FILE" ]; then
    [ -f "$HISTORY_HEADS_FILE" ] && [ ! -L "$HISTORY_HEADS_FILE" ] || return 1
    awk -F '\t' -v id="$id" '$1 != id' "$HISTORY_HEADS_FILE" > "$next" || return 1
  else
    : > "$next"
  fi
  printf '%s\t%s\t%s\n' "$id" "$hash" "$updated" >> "$next" || return 1
  fm_linear_atomic_file "$HISTORY_HEADS_FILE" 600 < "$next"
}

thread_participated() {  # <thread-id>
  awk -F '\t' -v id="$1" '$1 == id { found=1 } END { exit !found }' \
    "$THREAD_PARTICIPATION_FILE" 2>/dev/null
}

thread_participation_set() {  # <thread-id> <observed-at>
  local id=$1 observed=$2 next="$TMP_ROOT/thread-participation-next.tsv"
  [ -n "$id" ] || return 0
  thread_participated "$id" && return 0
  if [ -e "$THREAD_PARTICIPATION_FILE" ]; then
    [ -f "$THREAD_PARTICIPATION_FILE" ] && [ ! -L "$THREAD_PARTICIPATION_FILE" ] || return 1
    cp "$THREAD_PARTICIPATION_FILE" "$next" || return 1
  else
    : > "$next"
  fi
  printf '%s\t%s\n' "$id" "$observed" >> "$next" || return 1
  fm_linear_atomic_file "$THREAD_PARTICIPATION_FILE" 600 < "$next"
}

bootstrap_horizon() {  # <comments-cursor> <issues-cursor>
  local comments_cursor=$1 issues_cursor=$2 horizon
  if [ -n "$comments_cursor" ] && [ -n "$issues_cursor" ]; then
    return 0
  fi
  if [ -e "$BOOTSTRAP_HORIZON_FILE" ]; then
    [ -f "$BOOTSTRAP_HORIZON_FILE" ] && [ ! -L "$BOOTSTRAP_HORIZON_FILE" ] || return 1
    horizon=$(sed -n '1p' "$BOOTSTRAP_HORIZON_FILE")
    [ -n "$horizon" ] && horizon=$(fm_linear_normalize_timestamp "$horizon") || return 1
    printf '%s\n' "$horizon"
    return 0
  fi
  horizon=$(fm_linear_iso_from_epoch "$((${FM_LINEAR_NOW_EPOCH:-$(date +%s)} - 7200))") || return 1
  horizon=$(fm_linear_normalize_timestamp "$horizon") || return 1
  printf '%s\n' "$horizon" | fm_linear_atomic_file "$BOOTSTRAP_HORIZON_FILE" 600 || return 1
  printf '%s\n' "$horizon"
}

timestamp_max() {  # <left> <right>
  local left=$1 right=$2 left_normalized right_normalized
  [ -n "$right" ] || { printf '%s\n' "$left"; return 0; }
  [ -n "$left" ] || { printf '%s\n' "$right"; return 0; }
  left_normalized=$(fm_linear_normalize_timestamp "$left") || return 1
  right_normalized=$(fm_linear_normalize_timestamp "$right") || return 1
  if [[ "$right_normalized" > "$left_normalized" ]]; then
    printf '%s\n' "$right"
  else
    printf '%s\n' "$left"
  fi
}

json_array_append() {  # <array-file> <new-array-file>
  local destination=$1 addition=$2 output="$TMP_ROOT/array-merge.$$.json"
  jq -n --slurpfile old "$destination" --slurpfile new "$addition" \
    '$old[0] + $new[0]' > "$output" || return 1
  mv -f -- "$output" "$destination"
}

api() {  # <operation> <payload-file> <response-file>
  fm_linear_api_call "$1" "$2" "$3"
}

thread_root_cached() {  # <comment-id> <issue> <root-output-var-name>
  local cached_root
  cached_root=$(awk -F '\t' -v id="$1" -v issue="$2" '$1 == id && $3 == issue { print $2; exit }' \
    "$COMMENT_ROOTS_FILE" 2>/dev/null)
  [ -n "$cached_root" ] || return 1
  printf -v "$3" '%s' "$cached_root"
}

thread_root_cache_set() {  # <comment-id> <root-id> <issue>
  local id=$1 root=$2 issue=$3 next="$TMP_ROOT/comment-roots-next.tsv"
  if [ -e "$COMMENT_ROOTS_FILE" ]; then
    [ -f "$COMMENT_ROOTS_FILE" ] && [ ! -L "$COMMENT_ROOTS_FILE" ] || return 1
    awk -F '\t' -v id="$id" '$1 != id' "$COMMENT_ROOTS_FILE" > "$next" || return 1
  else
    : > "$next"
  fi
  printf '%s\t%s\t%s\n' "$id" "$root" "$issue" >> "$next" || return 1
  fm_linear_atomic_file "$COMMENT_ROOTS_FILE" 600 < "$next"
}

resolve_thread_root() {  # <comment-id> <issue> <root-output-var-name>
  local start=$1 issue=$2 output_var=$3 observed=${4:-} depth=0 payload response query parent author_id
  local current scan scan_id next visited_id root
  if thread_root_cached "$start" "$issue" root; then
    printf -v "$output_var" '%s' "$root"
    return 0
  fi
  fm_linear_private_dir "$THREAD_ROOT_SCAN_DIR" || return 1
  scan_id=$(printf '%s' "$start" | fm_linear_sha256) || return 1
  scan="$THREAD_ROOT_SCAN_DIR/$scan_id.json"
  if [ -e "$scan" ]; then
    [ -f "$scan" ] && [ ! -L "$scan" ] || return 1
    jq -e --arg start "$start" --arg issue "$issue" \
      '.start == $start and .issue == $issue and (.visited | type == "array")' \
      "$scan" >/dev/null 2>&1 || return 1
  else
    jq -n --arg start "$start" --arg issue "$issue" \
      '{start:$start,current:$start,issue:$issue,visited:[]}' \
      | fm_linear_atomic_file "$scan" 600 || return 1
  fi
  current=$(jq -r '.current' "$scan") || return 1
  while :; do
    depth=$((depth + 1))
    [ "$depth" -le 50 ] || {
      FM_LINEAR_API_ERROR="thread ancestry exceeded 50 comments"
      return 1
    }
    payload="$TMP_ROOT/thread-root-$depth-payload.json"
    response="$TMP_ROOT/thread-root-$depth-response.json"
    # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
    query='query($comment:String!){comment(id:$comment){id issue{identifier} parent{id} user{id}}}'
    jq -n --arg query "$query" --arg comment "$current" \
      '{query:$query,variables:{comment:$comment}}' > "$payload" || return 1
    api threadRoot "$payload" "$response" || return 1
    [ "$(jq -r '.data.comment.id // empty' "$response")" = "$current" ] \
      && [ "$(jq -r '.data.comment.issue.identifier // empty' "$response")" = "$issue" ] || {
      FM_LINEAR_API_ERROR="thread root does not belong to $issue"
      return 1
    }
    parent=$(jq -r '.data.comment.parent.id // empty' "$response")
    next="$TMP_ROOT/thread-root-progress-$scan_id.json"
    jq --arg current "$current" --arg parent "$parent" \
      '.visited=((.visited + [$current]) | unique) | .current=(if $parent == "" then $current else $parent end)' \
      "$scan" > "$next" || return 1
    fm_linear_atomic_file "$scan" 600 < "$next" || return 1
    if [ -z "$parent" ]; then
      author_id=$(jq -r '.data.comment.user.id // empty' "$response")
      if [ -n "$observed" ] && [ "$author_id" = "$SELF_ID" ]; then
        thread_participation_set "$current" "$observed" || return 1
      fi
      while IFS= read -r visited_id; do
        [ -n "$visited_id" ] || continue
        thread_root_cache_set "$visited_id" "$current" "$issue" || return 1
      done < <(jq -r '.visited[]' "$scan")
      rm -f -- "$scan" || return 1
      break
    fi
    current=$parent
  done
  printf -v "$output_var" '%s' "$current"
}

resolve_thread_participation() {  # <parent-comment-id> <issue> <observed-at> <root-output-var-name>
  local current resolved_root issue=$2 observed=$3 output_var=$4 payload response query after has_next end_cursor page
  local scan scan_id next node limit
  resolve_thread_root "$1" "$issue" resolved_root "$observed" || return 1
  current=$resolved_root
  printf -v "$output_var" '%s' "$current"
  thread_participated "$current" && return 0
  fm_linear_private_dir "$THREAD_DESCENDANT_SCAN_DIR" || return 1
  scan_id=$(printf '%s' "$current" | fm_linear_sha256) || return 1
  scan="$THREAD_DESCENDANT_SCAN_DIR/$scan_id.json"
  if [ -e "$scan" ]; then
    [ -f "$scan" ] && [ ! -L "$scan" ] || return 1
    jq -e --arg root "$current" --arg issue "$issue" \
      '.root == $root and .issue == $issue and (.queue | type == "array")
       and ((.children // []) | type == "array")' \
      "$scan" >/dev/null 2>&1 || return 1
  else
    jq -n --arg root "$current" --arg issue "$issue" \
      '{root:$root,issue:$issue,queue:[$root],current:null,after:null,children:[]}' \
      | fm_linear_atomic_file "$scan" 600 || return 1
  fi
  page=0
  limit=${FM_LINEAR_THREAD_PAGES_PER_POLL:-10}
  case "$limit" in ''|*[!0-9]*|0) limit=10 ;; esac
  while [ "$page" -lt "$limit" ]; do
    node=$(jq -r '.current // .queue[0] // empty' "$scan") || return 1
    if [ -z "$node" ]; then
      rm -f -- "$scan" || return 1
      return 0
    fi
    after=$(jq -r '.after // empty' "$scan") || return 1
    page=$((page + 1))
    payload="$TMP_ROOT/thread-participants-$page-payload.json"
    response="$TMP_ROOT/thread-participants-$page-response.json"
    # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
    query='query($comment:String!,$after:String){comment(id:$comment){id issue{identifier} children(first:50,after:$after,orderBy:updatedAt){pageInfo{hasNextPage endCursor} nodes{id user{id}}}}}'
    jq -n --arg query "$query" --arg comment "$node" --arg after "$after" \
      '{query:$query,variables:{comment:$comment,after:(if $after == "" then null else $after end)}}' \
      > "$payload" || return 1
    api threadParticipants "$payload" "$response" || return 1
    if [ "$(jq -r '.data.comment.id // empty' "$response")" != "$node" ] \
      || [ "$(jq -r '.data.comment.issue.identifier // empty' "$response")" != "$issue" ] \
      || ! jq -e '.data.comment.children.nodes | type == "array"' "$response" >/dev/null 2>&1; then
      FM_LINEAR_API_ERROR="malformed thread participation response for $node"
      return 1
    fi
    if jq -e --arg self "$SELF_ID" 'any(.data.comment.children.nodes[]; .user.id == $self)' \
      "$response" >/dev/null; then
      thread_participation_set "$current" "$observed" || return 1
      rm -f -- "$scan" || return 1
      return 0
    fi
    has_next=$(jq -r '.data.comment.children.pageInfo.hasNextPage // false' "$response")
    end_cursor=$(jq -r '.data.comment.children.pageInfo.endCursor // empty' "$response")
    [ "$has_next" != true ] || [ -n "$end_cursor" ] || {
      FM_LINEAR_API_ERROR="thread participation pagination omitted endCursor for $current"
      return 1
    }
    next="$TMP_ROOT/thread-descendants-$scan_id.json"
    jq --arg node "$node" --arg after "$end_cursor" --argjson has_next "$has_next" \
      --slurpfile response "$response" '
      ($response[0].data.comment.children.nodes | map(.id // empty) | map(select(length > 0))) as $page_children
      | (((.children // []) + $page_children) | unique) as $children
      | if $has_next then .current=$node | .after=$after | .children=$children
      else
        .queue=((.queue[1:] + $children) | unique)
        | .current=null | .after=null | .children=[]
      end' "$scan" > "$next" || return 1
    fm_linear_atomic_file "$scan" 600 < "$next" || return 1
  done
  return 3
}

bootstrap_comment_heads() {  # <event-bootstrap-cutoff>
  local cutoff=$1 after='' payload response viewer_id has_next end_cursor id body_b64 updated edited hash author_id parent thread issue query
  if [ -e "$COMMENT_HEAD_BOOTSTRAP_FILE" ]; then
    [ -f "$COMMENT_HEAD_BOOTSTRAP_FILE" ] && [ ! -L "$COMMENT_HEAD_BOOTSTRAP_FILE" ] || return 1
    jq -e 'type == "object" and (.complete | type == "boolean")' \
      "$COMMENT_HEAD_BOOTSTRAP_FILE" >/dev/null 2>&1 || {
      FM_LINEAR_API_ERROR="malformed comment-head bootstrap state"
      return 1
    }
    [ "$(jq -r '.complete' "$COMMENT_HEAD_BOOTSTRAP_FILE")" != true ] || return 0
    after=$(jq -r '.after // empty' "$COMMENT_HEAD_BOOTSTRAP_FILE")
    cutoff=$(jq -r '.before // empty' "$COMMENT_HEAD_BOOTSTRAP_FILE")
  fi
  if [ -z "$cutoff" ]; then
    cutoff=$(fm_linear_iso_from_epoch "$((${FM_LINEAR_NOW_EPOCH:-$(date +%s)} - 7200))") || {
      FM_LINEAR_API_ERROR="cannot calculate comment-head bootstrap horizon"
      return 1
    }
  fi
  payload="$TMP_ROOT/comment-head-bootstrap-payload.json"
  response="$TMP_ROOT/comment-head-bootstrap-response.json"
  # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
  query='query($after:String,$team:String!){viewer{id} comments(first:50,after:$after,orderBy:updatedAt,filter:{issue:{team:{key:{eq:$team}}},updatedAt:{lt:"'"$cutoff"'"}}){pageInfo{hasNextPage endCursor} nodes{id updatedAt editedAt body user{id} issue{identifier} parent{id}}}}'
  jq -n --arg query "$query" --arg after "$after" --arg team BIG \
    '{query:$query,variables:{after:(if $after == "" then null else $after end),team:$team}}' \
    > "$payload" || return 1
  api commentHeads "$payload" "$response" || return 1
  jq -e '(.data.viewer.id | type == "string" and length > 0)
    and (.data.comments.nodes | type == "array")' "$response" >/dev/null 2>&1 || {
    FM_LINEAR_API_ERROR="malformed comment-head bootstrap response"
    return 1
  }
  viewer_id=$(jq -r '.data.viewer.id' "$response")
  [ "$viewer_id" = "$SELF_ID" ] || {
    FM_LINEAR_API_ERROR="viewer identity changed during comment-head bootstrap"
    return 1
  }
  jq -r '.data.comments.nodes[]
    | [(.id // ""), ("b:" + ((.body // "") | @base64)), (.updatedAt // ""),
       (.editedAt // "__FM_LINEAR_EMPTY__"),
       (.user.id // "__FM_LINEAR_EMPTY__"),(.parent.id // "__FM_LINEAR_EMPTY__"),
       (.issue.identifier // "__FM_LINEAR_EMPTY__")]
    | @tsv' "$response" > "$TMP_ROOT/comment-head-bootstrap.tsv" || return 1
  while IFS="$(printf '\t')" read -r id body_b64 updated edited author_id parent issue; do
    [ -n "$id" ] && [ -n "$updated" ] || return 1
    body_b64=${body_b64#b:}
    hash=$(printf '%s' "$body_b64" | base64 --decode | fm_linear_sha256) || return 1
    [ "$edited" != __FM_LINEAR_EMPTY__ ] || edited=
    updated=$(fm_linear_normalize_timestamp "$updated") || return 1
    [ -z "$edited" ] || edited=$(fm_linear_normalize_timestamp "$edited") || return 1
    comment_head_seed "$id" "$hash" "$edited" "$updated" || return 1
    [ "$author_id" != __FM_LINEAR_EMPTY__ ] || author_id=
    [ "$parent" != __FM_LINEAR_EMPTY__ ] || parent=
    [ "$issue" != __FM_LINEAR_EMPTY__ ] || issue=
    if [ -n "$author_id" ] && [ "$author_id" = "$SELF_ID" ]; then
      if [ -n "$parent" ]; then
        resolve_thread_root "$parent" "$issue" thread "$updated" || return 1
      else
        thread=$id
      fi
      thread_participation_set "$thread" "$updated" || return 1
    fi
  done < "$TMP_ROOT/comment-head-bootstrap.tsv"
  has_next=$(jq -r '.data.comments.pageInfo.hasNextPage // false' "$response")
  end_cursor=$(jq -r '.data.comments.pageInfo.endCursor // empty' "$response")
  if [ "$has_next" = true ] && [ -z "$end_cursor" ]; then
    FM_LINEAR_API_ERROR="comment-head bootstrap omitted endCursor"
    return 1
  fi
  jq -n --arg after "$end_cursor" --arg before "$cutoff" \
    --argjson complete "$([ "$has_next" = true ] && printf false || printf true)" \
    '{after:(if $after == "" then null else $after end),before:$before,complete:$complete}' \
    | fm_linear_atomic_file "$COMMENT_HEAD_BOOTSTRAP_FILE" 600
}

fetch_comments() {  # <cursor> <bootstrap-cutoff>
  local cursor=$1 bootstrap_cutoff=$2 after='' since='' payload response page has_next end_cursor nodes viewer_id viewer_name query
  page=0
  : > "$TMP_ROOT/comments.json"
  printf '[]\n' > "$TMP_ROOT/comments.json"
  if [ -n "$cursor" ]; then
    since=$(fm_linear_overlap_timestamp "$cursor") || {
      FM_LINEAR_API_ERROR="invalid comments cursor"
      return 1
    }
    since=$(fm_linear_normalize_timestamp "$since") || return 1
  elif [ -n "$bootstrap_cutoff" ]; then
    since=$bootstrap_cutoff
  fi
  while :; do
    page=$((page + 1))
    [ "$page" -le "${FM_LINEAR_MAX_PAGES:-100}" ] || {
      FM_LINEAR_API_ERROR="comments pagination exceeded limit"
      return 1
    }
    payload="$TMP_ROOT/comments-payload-$page.json"
    response="$TMP_ROOT/comments-response-$page.json"
    if [ -n "$since" ]; then
      # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
      query='query($after:String,$team:String!){viewer{id displayName} comments(first:50,after:$after,orderBy:updatedAt,filter:{issue:{team:{key:{eq:$team}}},updatedAt:{gte:"'"$since"'"}}){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt editedAt body user{id displayName} issue{identifier labels{nodes{name}}} parent{id}}}}'
    else
      # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
      query='query($after:String,$team:String!){viewer{id displayName} comments(first:50,after:$after,orderBy:updatedAt,filter:{issue:{team:{key:{eq:$team}}}}){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt editedAt body user{id displayName} issue{identifier labels{nodes{name}}} parent{id}}}}'
    fi
    jq -n --arg query "$query" --arg after "$after" --arg team BIG \
      '{query:$query,variables:{after:(if $after == "" then null else $after end),team:$team}}' \
      > "$payload" || return 1
    api comments "$payload" "$response" || return 1
    jq -e '(.data.viewer.id | type == "string" and length > 0)
      and (.data.comments.nodes | type == "array")' "$response" >/dev/null 2>&1 || {
      FM_LINEAR_API_ERROR="malformed comments response"
      return 1
    }
    viewer_id=$(jq -r '.data.viewer.id' "$response")
    viewer_name=$(jq -r '.data.viewer.displayName // empty' "$response")
    if [ -n "$SELF_ID" ] && [ "$SELF_ID" != "$viewer_id" ]; then
      FM_LINEAR_API_ERROR="viewer identity changed during comments pagination"
      return 1
    fi
    SELF_ID=$viewer_id
    [ -z "$viewer_name" ] || SELF_NAME=$viewer_name
    nodes="$TMP_ROOT/comments-nodes-$page.json"
    fm_linear_normalize_json_timestamps comments < "$response" > "$nodes" || return 1
    json_array_append "$TMP_ROOT/comments.json" "$nodes" || return 1
    has_next=$(jq -r '.data.comments.pageInfo.hasNextPage // false' "$response")
    [ "$has_next" = true ] || break
    end_cursor=$(jq -r '.data.comments.pageInfo.endCursor // empty' "$response")
    [ -n "$end_cursor" ] || {
      FM_LINEAR_API_ERROR="comments pagination omitted endCursor"
      return 1
    }
    after=$end_cursor
  done
}

append_initial_histories() {  # <issues-response> <page-number>
  local response=$1 page=$2 nodes
  nodes="$TMP_ROOT/history-initial-$page.json"
  jq '[.data.issues.nodes[] as $issue
        | $issue.history.nodes[]?
        | . + {issue:$issue.identifier}]' \
    "$response" > "$nodes" || return 1
  json_array_append "$TMP_ROOT/history.json" "$nodes"
}

fetch_more_history() {  # <scan-file>
  local scan=$1 issue after threshold page=0 payload response nodes has_next end_cursor oldest query next limit
  issue=$(jq -r '.issue' "$scan") || return 1
  after=$(jq -r '.after // empty' "$scan") || return 1
  threshold=$(jq -r '.threshold // empty' "$scan") || return 1
  limit=${FM_LINEAR_HISTORY_PAGES_PER_POLL:-1}
  case "$limit" in ''|*[!0-9]*|0) limit=1 ;; esac
  # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
  query='query($id:String!,$after:String){issue(id:$id){history(first:10,after:$after,orderBy:updatedAt){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt changes actor{id displayName} fromState{id name} toState{id name} fromAssignee{id displayName} toAssignee{id displayName} fromTitle toTitle fromPriority toPriority fromProject{id name} toProject{id name} fromParent{id identifier} toParent{id identifier} fromDueDate toDueDate updatedDescription addedLabels{id name} removedLabels{id name}}}}}'
  while [ "$page" -lt "$limit" ]; do
    page=$((page + 1))
    payload="$TMP_ROOT/history-$issue-payload-$page.json"
    response="$TMP_ROOT/history-$issue-response-$page.json"
    jq -n --arg query "$query" --arg id "$issue" --arg after "$after" \
      '{query:$query,variables:{id:$id,after:$after}}' > "$payload" || return 1
    api history "$payload" "$response" || return 1
    jq -e '.data.issue.history.nodes | type == "array"' "$response" >/dev/null 2>&1 || {
      FM_LINEAR_API_ERROR="malformed history response for $issue"
      return 1
    }
    nodes="$TMP_ROOT/history-$issue-nodes-$page.json"
    fm_linear_normalize_json_timestamps history "$issue" < "$response" > "$nodes" || return 1
    has_next=$(jq -r '.data.issue.history.pageInfo.hasNextPage // false' "$response")
    oldest=$(jq -r '[.[].updatedAt] | min // empty' "$nodes")
    end_cursor=$(jq -r '.data.issue.history.pageInfo.endCursor // empty' "$response")
    if [ "$has_next" = true ] && [ -z "$end_cursor" ]; then
      FM_LINEAR_API_ERROR="history pagination omitted endCursor for $issue"
      return 1
    fi
    next="$TMP_ROOT/history-scan-$issue.json"
    jq -n --slurpfile scan "$scan" --slurpfile additions "$nodes" \
      --arg after "$end_cursor" '
      $scan[0]
      | .after=(if $after == "" then null else $after end)
      | .nodes=((.nodes + $additions[0]) | unique_by([.id,.updatedAt,(.changes|tostring)]))' \
      > "$next" || return 1
    fm_linear_atomic_file "$scan" 600 < "$next" || return 1
    after=$end_cursor
    if [ "$has_next" != true ] \
      || { [ -n "$threshold" ] && [ -n "$oldest" ] && [[ "$oldest" < "$threshold" ]]; }; then
      jq -n --slurpfile scan "$scan" '
        ($scan[0].snapshots // [$scan[0].issue_node])
        | sort_by(.updatedAt)
        | map(. + {_scan_threshold:$scan[0].threshold})
      ' > "$nodes" || return 1
      json_array_append "$TMP_ROOT/issues.json" "$nodes" || return 1
      jq -n --slurpfile scan "$scan" \
        '$scan[0].nodes | map(. + {_scan_threshold:$scan[0].threshold})' > "$nodes" || return 1
      json_array_append "$TMP_ROOT/history.json" "$nodes" || return 1
      rm -f -- "$scan" || return 1
      return 0
    fi
  done
  return 3
}

fetch_issues() {  # <cursor> <bootstrap-cutoff>
  local cursor=$1 bootstrap_cutoff=$2 after='' since='' payload response page has_next end_cursor nodes query
  local history_list page_history_list issue history_after threshold scan issue_json history_json normalized scan_next
  printf '[]\n' > "$TMP_ROOT/issues.json"
  printf '[]\n' > "$TMP_ROOT/issues-audit.json"
  printf '[]\n' > "$TMP_ROOT/history.json"
  fm_linear_private_dir "$HISTORY_SCAN_DIR" || return 1
  if [ -n "$cursor" ]; then
    since=$(fm_linear_overlap_timestamp "$cursor") || {
      FM_LINEAR_API_ERROR="invalid issues cursor"
      return 1
    }
    since=$(fm_linear_normalize_timestamp "$since") || return 1
  elif [ -n "$bootstrap_cutoff" ]; then
    since=$bootstrap_cutoff
  fi
  page=0
  history_list="$TMP_ROOT/history-pagination.tsv"
  : > "$history_list"
  while :; do
    page=$((page + 1))
    [ "$page" -le "${FM_LINEAR_MAX_PAGES:-100}" ] || {
      FM_LINEAR_API_ERROR="issues pagination exceeded limit"
      return 1
    }
    payload="$TMP_ROOT/issues-payload-$page.json"
    response="$TMP_ROOT/issues-response-$page.json"
    if [ -n "$since" ]; then
      # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
      query='query($after:String){issues(first:50,after:$after,orderBy:updatedAt,filter:{team:{key:{eq:"BIG"}},updatedAt:{gte:"'"$since"'"}}){pageInfo{hasNextPage endCursor} nodes{identifier title description priority dueDate updatedAt createdAt state{id name} assignee{id displayName} creator{id displayName} project{id name} parent{id identifier} labels{nodes{name}} history(first:10,orderBy:updatedAt){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt changes actor{id displayName} fromState{id name} toState{id name} fromAssignee{id displayName} toAssignee{id displayName} fromTitle toTitle fromPriority toPriority fromProject{id name} toProject{id name} fromParent{id identifier} toParent{id identifier} fromDueDate toDueDate updatedDescription addedLabels{id name} removedLabels{id name}}}}}}'
    else
      # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
      query='query($after:String){issues(first:50,after:$after,orderBy:updatedAt,filter:{team:{key:{eq:"BIG"}}}){pageInfo{hasNextPage endCursor} nodes{identifier title description priority dueDate updatedAt createdAt state{id name} assignee{id displayName} creator{id displayName} project{id name} parent{id identifier} labels{nodes{name}} history(first:10,orderBy:updatedAt){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt changes actor{id displayName} fromState{id name} toState{id name} fromAssignee{id displayName} toAssignee{id displayName} fromTitle toTitle fromPriority toPriority fromProject{id name} toProject{id name} fromParent{id identifier} toParent{id identifier} fromDueDate toDueDate updatedDescription addedLabels{id name} removedLabels{id name}}}}}}'
    fi
    jq -n --arg query "$query" --arg after "$after" \
      '{query:$query,variables:{after:(if $after == "" then null else $after end)}}' > "$payload" || return 1
    api issues "$payload" "$response" || return 1
    jq -e '.data.issues.nodes | type == "array"' "$response" >/dev/null 2>&1 || {
      FM_LINEAR_API_ERROR="malformed issues response"
      return 1
    }
    normalized="$TMP_ROOT/issues-normalized-$page.json"
    page_history_list="$TMP_ROOT/history-pagination-$page.tsv"
    fm_linear_normalize_json_timestamps issues < "$response" > "$normalized" || return 1
    mv -f -- "$normalized" "$response" || return 1
    nodes="$TMP_ROOT/issues-audit-nodes-$page.json"
    jq '.data.issues.nodes' "$response" > "$nodes" || return 1
    json_array_append "$TMP_ROOT/issues-audit.json" "$nodes" || return 1
    threshold=$since
    jq -r --arg threshold "$threshold" '
      .data.issues.nodes[]
      | select(.history.pageInfo.hasNextPage == true)
      | (.history.nodes | length) as $count
      | ([.history.nodes[].updatedAt] | min // "") as $oldest
      | select($threshold == "" or $oldest == "" or $oldest >= $threshold)
      | [.identifier, (.history.pageInfo.endCursor // ""), $oldest, ($count|tostring)]
      | @tsv
    ' "$response" > "$page_history_list" || return 1
    cat "$page_history_list" >> "$history_list" || return 1
    while IFS="$(printf '\t')" read -r issue history_after _; do
      [ -n "$issue" ] || continue
      [ -n "$history_after" ] || {
        FM_LINEAR_API_ERROR="history pagination omitted endCursor for $issue"
        return 1
      }
      scan="$HISTORY_SCAN_DIR/$issue.json"
      issue_json=$(jq -c --arg issue "$issue" '.data.issues.nodes[] | select(.identifier == $issue)' "$response") || return 1
      history_json=$(printf '%s' "$issue_json" | jq -c --arg issue "$issue" '[.history.nodes[] | . + {issue:$issue}]') || return 1
      if [ -e "$scan" ]; then
        [ -f "$scan" ] && [ ! -L "$scan" ] || return 1
        scan_next="$TMP_ROOT/history-scan-merge-$issue.json"
        jq -n --slurpfile old "$scan" --argjson issue_node "$issue_json" \
          --argjson additions "$history_json" --arg after "$history_after" --arg threshold "$threshold" '
          $old[0]
          | .snapshots=(((.snapshots // [.issue_node]) + [$issue_node])
              | unique_by(.updatedAt) | sort_by(.updatedAt))
          | if .issue_node.updatedAt == $issue_node.updatedAt then .
            else .issue_node=$issue_node | .after=$after
              | .nodes=((.nodes + $additions) | unique_by([.id,.updatedAt,(.changes|tostring)]))
            end' \
          > "$scan_next" || return 1
        fm_linear_atomic_file "$scan" 600 < "$scan_next" || return 1
      else
        jq -n --arg issue "$issue" --arg after "$history_after" --arg threshold "$threshold" \
          --argjson issue_node "$issue_json" --argjson nodes "$history_json" \
          '{issue:$issue,after:$after,threshold:$threshold,issue_node:$issue_node,
            snapshots:[$issue_node],nodes:$nodes}' \
          | fm_linear_atomic_file "$scan" 600 || return 1
      fi
    done < "$page_history_list"
    nodes="$TMP_ROOT/issues-nodes-$page.json"
    jq '.data.issues.nodes' "$response" > "$nodes" || return 1
    while IFS="$(printf '\t')" read -r issue _; do
      [ -n "$issue" ] || continue
      jq --arg issue "$issue" '[.[] | select(.identifier != $issue)]' "$nodes" > "$nodes.next" || return 1
      mv -f -- "$nodes.next" "$nodes" || return 1
    done < "$page_history_list"
    json_array_append "$TMP_ROOT/issues.json" "$nodes" || return 1
    append_initial_histories "$response" "$page" || return 1
    while IFS="$(printf '\t')" read -r issue _; do
      [ -n "$issue" ] || continue
      jq --arg issue "$issue" '[.[] | select(.issue != $issue)]' "$TMP_ROOT/history.json" \
        > "$TMP_ROOT/history.json.next" || return 1
      mv -f -- "$TMP_ROOT/history.json.next" "$TMP_ROOT/history.json" || return 1
    done < "$page_history_list"
    has_next=$(jq -r '.data.issues.pageInfo.hasNextPage // false' "$response")
    [ "$has_next" = true ] || break
    end_cursor=$(jq -r '.data.issues.pageInfo.endCursor // empty' "$response")
    [ -n "$end_cursor" ] || {
      FM_LINEAR_API_ERROR="issues pagination omitted endCursor"
      return 1
    }
    after=$end_cursor
  done
  for scan in "$HISTORY_SCAN_DIR"/*.json; do
    [ -f "$scan" ] || continue
    fetch_more_history "$scan"
    case $? in 0|3) ;; *) return 1 ;; esac
  done
}

publish_inbox() {  # <dedupe-key> <record-file>
  local key=$1 record=$2 basename destination
  basename=$(printf '%s' "$key" | fm_linear_sha256) || return 1
  destination="$INBOX/$basename.json"
  if [ -e "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  else
    fm_linear_atomic_file "$destination" 600 < "$record" || return 1
  fi
}

note_issue() {
  case " $NEW_ISSUES " in *" $1 "*) ;; *) NEW_ISSUES="$NEW_ISSUES $1" ;; esac
}

note_observation_issue() {
  case " $NEW_OBSERVATION_ISSUES " in *" $1 "*) ;; *) NEW_OBSERVATION_ISSUES="$NEW_OBSERVATION_ISSUES $1" ;; esac
}

record_event_count() {  # <authority> <issue>
  if [ "$1" = captain ]; then
    NEW_EVENTS=$((NEW_EVENTS + 1))
    note_issue "$2"
  else
    NEW_OBSERVATIONS=$((NEW_OBSERVATIONS + 1))
    note_observation_issue "$2"
  fi
}

publish_outbox_observation_marker() {  # <marker>
  local marker=$1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || {
      FM_LINEAR_API_ERROR="unsafe outbox observation marker: ${marker##*/}"
      return 1
    }
    return 0
  fi
  fm_linear_atomic_file "$marker" 600 </dev/null || {
    FM_LINEAR_API_ERROR="cannot publish outbox observation marker: ${marker##*/}"
    return 1
  }
}

mark_outbox_comment_observed() {  # <comment-id>
  local comment_id=$1 journal marker
  [ -d "$OUTBOX" ] || return 0
  for journal in "$OUTBOX"/*.done; do
    [ -f "$journal" ] || continue
    [ ! -L "$journal" ] || {
      FM_LINEAR_API_ERROR="unsafe completed write journal: ${journal##*/}"
      return 1
    }
    [ "$(jq -r '.comment_id // empty' "$journal" 2>/dev/null)" = "$comment_id" ] || continue
    marker="${journal%.*}.comment-observed"
    publish_outbox_observation_marker "$marker" || return 1
  done
}

reconcile_outbox_snapshot_board() {  # <issue> <updated-at> <state-id> <assignee-id>
  local issue=$1 updated=$2 state_id=$3 assignee_id=$4 journal journal_updated marker
  [ -d "$OUTBOX" ] || return 1
  updated=$(fm_linear_normalize_timestamp "$updated") || return 2
  for journal in "$OUTBOX"/*.done; do
    [ -f "$journal" ] || continue
    [ ! -L "$journal" ] || {
      FM_LINEAR_API_ERROR="unsafe completed write journal: ${journal##*/}"
      return 2
    }
    [ "$(jq -r '.issue // empty' "$journal" 2>/dev/null)" = "$issue" ] || continue
    [ "$(jq -r 'if has("mutation_sent") then .mutation_sent else false end' "$journal" 2>/dev/null)" = true ] \
      || continue
    [ "$(jq -r '.state_id // empty' "$journal" 2>/dev/null)" = "$state_id" ] || continue
    [ "$(jq -r '.assignee_id // empty' "$journal" 2>/dev/null)" = "$assignee_id" ] || continue
    journal_updated=$(jq -r '.mutated_updated_at // empty' "$journal" 2>/dev/null)
    [ -n "$journal_updated" ] || continue
    journal_updated=$(fm_linear_normalize_timestamp "$journal_updated") || {
      FM_LINEAR_API_ERROR="invalid mutation provenance in completed write journal: ${journal##*/}"
      return 2
    }
    [ "$journal_updated" = "$updated" ] || continue
    marker="${journal%.*}.board-observed"
    publish_outbox_observation_marker "$marker" || return 2
    return 0
  done
  return 1
}

mark_outbox_board_observed() {  # <issue> <updated-at> <to-state-id> <to-assignee-id>
  local status
  if reconcile_outbox_snapshot_board "$1" "$2" "$3" "$4"; then
    return 0
  else
    status=$?
    [ "$status" -eq 1 ] || return 1
  fi
}

reconcile_fetched_outbox_boards() {
  local row issue updated state_id assignee_id status
  jq -c '.[]' "$TMP_ROOT/issues-audit.json" > "$TMP_ROOT/outbox-board-rows.jsonl" || return 1
  while IFS= read -r row; do
    issue=$(printf '%s' "$row" | jq -r '.identifier // empty') || return 1
    updated=$(printf '%s' "$row" | jq -r '.updatedAt // empty') || return 1
    state_id=$(printf '%s' "$row" | jq -r '.state.id // empty') || return 1
    assignee_id=$(printf '%s' "$row" | jq -r '.assignee.id // empty') || return 1
    [ -n "$issue" ] && [ -n "$updated" ] && [ -n "$state_id" ] || continue
    if reconcile_outbox_snapshot_board "$issue" "$updated" "$state_id" "$assignee_id"; then
      continue
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
    fi
  done < "$TMP_ROOT/outbox-board-rows.jsonl"
}

derive_comments() {  # <observed-at> <bootstrap-cutoff>
  local observed=$1 bootstrap_cutoff=$2 id body_b64 body_file author_id author issue parent created updated edited hash key record authority
  local labels_b64 labels labeled body_lower mention_lower should_wake route thread bootstrap_complete head_cutoff participation_status
  bootstrap_complete=$(jq -r '.complete // false' "$COMMENT_HEAD_BOOTSTRAP_FILE" 2>/dev/null || printf false)
  head_cutoff=$(jq -r '.before // empty' "$COMMENT_HEAD_BOOTSTRAP_FILE" 2>/dev/null || true)
  [ -n "$head_cutoff" ] || head_cutoff=$bootstrap_cutoff
  [ -z "$head_cutoff" ] || head_cutoff=$(fm_linear_normalize_timestamp "$head_cutoff") || return 1
  [ -z "$bootstrap_cutoff" ] || bootstrap_cutoff=$(fm_linear_normalize_timestamp "$bootstrap_cutoff") || return 1
  mention_lower=$(printf '%s' "$SELF_MENTION" | tr '[:upper:]' '[:lower:]')
  jq -r 'sort_by(.updatedAt, .id)[]
    | [(.id // "__FM_LINEAR_EMPTY__"), ("b:" + ((.body // "") | @base64)),
       (.user.id // "__FM_LINEAR_EMPTY__"), (.user.displayName // "unknown"),
       (.issue.identifier // "unknown"), (.parent.id // "__FM_LINEAR_EMPTY__"),
       (.createdAt // "__FM_LINEAR_EMPTY__"), (.updatedAt // "__FM_LINEAR_EMPTY__"),
       (.editedAt // "__FM_LINEAR_EMPTY__"),
       ((.issue.labels.nodes // [] | map(.name) | tojson) | @base64)]
    | @tsv
  ' "$TMP_ROOT/comments.json" > "$TMP_ROOT/comment-rows.tsv" || return 1
  jq -r --arg self "$SELF_ID" '.[]
    | select(.user.id == $self)
    | [(.parent.id // ""), (.id // ""), (.issue.identifier // ""), (.updatedAt // "")]
    | @tsv' "$TMP_ROOT/comments.json" > "$TMP_ROOT/comment-participation.tsv" || return 1
  : > "$TMP_ROOT/comment-roots.tsv"
  while IFS="$(printf '\t')" read -r parent id issue updated; do
    [ -n "$id" ] && [ -n "$updated" ] || continue
    if [ -n "$parent" ]; then
      resolve_thread_root "$parent" "$issue" thread "$updated" || return 1
    else
      thread=$id
    fi
    thread_participation_set "$thread" "$updated" || return 1
    printf '%s\t%s\n' "$id" "$thread" >> "$TMP_ROOT/comment-roots.tsv" || return 1
  done < "$TMP_ROOT/comment-participation.tsv"
  while IFS="$(printf '\t')" read -r id body_b64 author_id author issue parent created updated edited labels_b64; do
    [ "$id" != __FM_LINEAR_EMPTY__ ] || id=
    body_b64=${body_b64#b:}
    [ "$author_id" != __FM_LINEAR_EMPTY__ ] || author_id=
    [ "$parent" != __FM_LINEAR_EMPTY__ ] || parent=
    [ "$created" != __FM_LINEAR_EMPTY__ ] || created=
    [ "$updated" != __FM_LINEAR_EMPTY__ ] || updated=
    [ "$edited" != __FM_LINEAR_EMPTY__ ] || edited=
    [ -n "$id" ] && [ -n "$updated" ] || return 1
    labels=$(printf '%s' "$labels_b64" | base64 --decode) || return 1
    labeled=$(printf '%s' "$labels" | jq -r 'any(. == "Firstmate")') || return 1
    thread=$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$TMP_ROOT/comment-roots.tsv")
    if [ -n "$thread" ]; then
      :
    elif [ -n "$parent" ]; then
      resolve_thread_root "$parent" "$issue" thread "$observed" || return 1
    else
      thread=$id
    fi
    hash=$(printf '%s' "$body_b64" | base64 --decode | fm_linear_sha256) || return 1
    if comment_head_current "$id" "$hash" "$edited"; then
      if [ -n "$author_id" ] && [ "$author_id" = "$SELF_ID" ]; then
        thread_participation_set "$thread" "$observed" || return 1
        mark_outbox_comment_observed "$id" || return 1
      fi
      continue
    fi
    key="comment:$id:${edited:-$updated}:$hash"
    if ! comment_hash_known "$id" && [ "$bootstrap_complete" != true ] \
      && [ -n "$head_cutoff" ] && [ -n "$created" ] && [[ "$created" < "$head_cutoff" ]] \
      && { [ -z "$edited" ] || [[ "$edited" < "$head_cutoff" ]]; }; then
      comment_head_set "$id" "$hash" "$edited" "$observed" || return 1
      continue
    fi
    if [ -n "$bootstrap_cutoff" ] && [[ "$updated" < "$bootstrap_cutoff" ]]; then
      comment_head_set "$id" "$hash" "$edited" "$observed" || return 1
      continue
    fi
    if [ -n "$author_id" ] && [ "$author_id" = "$SELF_ID" ]; then
      comment_head_set "$id" "$hash" "$edited" "$observed" || return 1
      thread_participation_set "$thread" "$observed" || return 1
      mark_outbox_comment_observed "$id" || return 1
      continue
    fi
    body_file="$TMP_ROOT/comment-body-$id"
    printf '%s' "$body_b64" | base64 --decode > "$body_file" || return 1
    body_lower=$(tr '[:upper:]' '[:lower:]' < "$body_file")
    should_wake=0
    route=ignored
    if [ "$labeled" = true ]; then
      should_wake=1
      route=label
    elif [ -n "$parent" ] && thread_participated "$thread"; then
      should_wake=1
      route=thread
    elif case "$body_lower" in *"$mention_lower"*) true ;; *) false ;; esac; then
      should_wake=1
      route=mention
    elif [ -n "$parent" ] && [ "$bootstrap_complete" != true ]; then
      resolve_thread_participation "$parent" "$issue" "$observed" thread
      participation_status=$?
      case "$participation_status" in
        0) ;;
        3) COMMENT_SCAN_PENDING=1; continue ;;
        *) return 1 ;;
      esac
      if thread_participated "$thread"; then
        should_wake=1
        route=thread
      fi
    fi
    if [ "$should_wake" -eq 0 ]; then
      comment_head_set "$id" "$hash" "$edited" "$observed" || return 1
      continue
    fi
    if [ "$author_id" = "$FM_LINEAR_CAPTAIN_ID" ]; then
      authority=captain
    elif [ -n "$author_id" ]; then
      authority=non-captain
    else
      authority=unattributed
    fi
    record="$TMP_ROOT/inbox-comment-$id.json"
    jq -n --arg issue "$issue" --arg id "$id" \
      --arg parent "$parent" --arg author "$author" --arg created "$created" \
      --arg author_id "$author_id" \
      --arg updated "$updated" --arg hash "$hash" --rawfile body "$body_file" \
      --arg observed "$observed" --arg cutoff "$bootstrap_cutoff" \
      --arg thread "$thread" --arg route "$route" --arg authority "$authority" --arg edited "$edited" '
        {kind:"comment", issue:$issue, comment_id:$id,
         parent_id:(if $parent == "" then null else $parent end), author:$author,
         author_id:(if $author_id == "" then null else $author_id end),
         thread_id:$thread, route:$route, authority:$authority,
         created_at:$created, updated_at:$updated,
         edited_at:(if $edited == "" then null else $edited end), body_sha256:$hash, body:$body,
         excerpt:($body[0:300]), observed_at:$observed}
        + (if $cutoff != "" and $updated >= $cutoff then {bootstrap:true} else {} end)
      ' > "$record" || return 1
    publish_inbox "$key" "$record" || return 1
    comment_head_set "$id" "$hash" "$edited" "$observed" || return 1
    record_event_count "$authority" "$issue"
  done < "$TMP_ROOT/comment-rows.tsv"
}

derive_history() {  # <observed-at> <event-cutoff> <bootstrap-cutoff>
  local observed=$1 event_cutoff=$2 bootstrap_cutoff=$3 row content id actor_id issue created updated hash key kind record row_cutoff
  local has_board has_description has_labels has_other to_state_id to_assignee_id authority
  jq -c 'sort_by((.updatedAt // .createdAt), .id)[]' "$TMP_ROOT/history.json" \
    > "$TMP_ROOT/history-rows.jsonl" || return 1
  while IFS= read -r row; do
    id=$(printf '%s' "$row" | jq -r '.id // empty')
    actor_id=$(printf '%s' "$row" | jq -r '.actor.id // empty')
    issue=$(printf '%s' "$row" | jq -r '.issue // "unknown"')
    created=$(printf '%s' "$row" | jq -r '.createdAt // empty')
    updated=$(printf '%s' "$row" | jq -r '.updatedAt // .createdAt // empty')
    row_cutoff=$(printf '%s' "$row" | jq -r '._scan_threshold // empty')
    [ -n "$row_cutoff" ] || row_cutoff=$event_cutoff
    [ -n "$id" ] && [ -n "$created" ] && [ -n "$updated" ] || return 1
    content=$(printf '%s' "$row" | jq -cS '
      def description_target:
        try (.changes.description // .changes.descriptionMarkdown // .changes.descriptionText) catch null
        | if type == "array" then .[-1]
          elif type == "object" then (.to // .newValue // .new // null)
          elif type == "string" then .
          else null end;
      {actor_id:(.actor.id // null),changes:(.changes // null),
      from_state:(.fromState // null),to_state:(.toState // null),
      from_assignee:(.fromAssignee // null),to_assignee:(.toAssignee // null),
      from_title:(.fromTitle // null),to_title:(.toTitle // null),
      from_priority:(.fromPriority // null),to_priority:(.toPriority // null),
      from_project:(.fromProject // null),to_project:(.toProject // null),
      from_parent:(.fromParent // null),to_parent:(.toParent // null),
      from_due_date:(.fromDueDate // null),to_due_date:(.toDueDate // null),
      description_updated:(.updatedDescription == true),
      description:(if .updatedDescription == true then description_target else null end),
      added_labels:((.addedLabels // []) | map({id:(.id // null),name})),
      removed_labels:((.removedLabels // []) | map({id:(.id // null),name}))}') || return 1
    hash=$(printf '%s' "$content" | fm_linear_sha256) || return 1
    has_board=$(printf '%s' "$row" | jq -r '.fromState != null or .toState != null or .fromAssignee != null or .toAssignee != null')
    has_description=$(printf '%s' "$content" | jq -r '.description_updated == true and .description != null')
    has_labels=$(printf '%s' "$row" | jq -r '((.addedLabels // []) | length) + ((.removedLabels // []) | length) > 0')
    has_other=$(printf '%s' "$row" | jq -r '.fromTitle != null or .toTitle != null
      or .fromPriority != null or .toPriority != null or .fromProject != null or .toProject != null
      or .fromParent != null or .toParent != null or .fromDueDate != null or .toDueDate != null')
    to_state_id=$(printf '%s' "$row" | jq -r '.toState.id // empty')
    to_assignee_id=$(printf '%s' "$row" | jq -r '.toAssignee.id // empty')
    if history_hash_current "$id" "$hash"; then
      if [ -n "$actor_id" ] && [ "$actor_id" = "$SELF_ID" ] && [ "$has_board" = true ]; then
        mark_outbox_board_observed "$issue" "$updated" "$to_state_id" "$to_assignee_id" || return 1
      fi
      continue
    fi
    if [ -n "$row_cutoff" ] && [[ "$updated" < "$row_cutoff" ]]; then
      history_hash_set "$id" "$hash" "$updated" || return 1
      continue
    fi
    if [ -n "$actor_id" ] && [ "$actor_id" = "$SELF_ID" ]; then
      history_hash_set "$id" "$hash" "$updated" || return 1
      if [ "$has_board" = true ]; then
        mark_outbox_board_observed "$issue" "$updated" "$to_state_id" "$to_assignee_id" || return 1
      fi
      continue
    fi
    if [ "$actor_id" = "$FM_LINEAR_CAPTAIN_ID" ]; then
      authority=captain
    elif [ -n "$actor_id" ]; then
      authority=non-captain
    else
      authority=unattributed
    fi
    if [ "$has_board" = true ]; then
      kind=board
    elif [ "$has_description" = true ] && [ "$has_labels" != true ] && [ "$has_other" != true ]; then
      kind=description
    elif [ "$has_labels" = true ] && [ "$has_other" != true ]; then
      kind=label
    elif [ "$has_other" = true ]; then
      kind='issue-change'
    else
      history_hash_set "$id" "$hash" "$updated" || return 1
      continue
    fi
    key="history:$id:$updated:$hash"
    record="$TMP_ROOT/inbox-history-$id.json"
    printf '%s' "$row" | jq --arg kind "$kind" --arg observed "$observed" \
      --arg authority "$authority" \
      --arg cutoff "$bootstrap_cutoff" --arg hash "$hash" --argjson content "$content" '
      {kind:$kind, issue:.issue, history_id:.id, history_sha256:$hash, authority:$authority,
       author:(.actor.displayName // "unknown"), author_id:(.actor.id // null),
       created_at:.createdAt, updated_at:(.updatedAt // .createdAt), observed_at:$observed,
       changes:(.changes // null),
       from_state:(.fromState.name // null), from_state_id:(.fromState.id // null),
       to_state:(.toState.name // null), to_state_id:(.toState.id // null),
       from_assignee:(.fromAssignee.displayName // null), from_assignee_id:(.fromAssignee.id // null),
       to_assignee:(.toAssignee.displayName // null), to_assignee_id:(.toAssignee.id // null),
       from_title:(.fromTitle // null), to_title:(.toTitle // null),
       from_priority:(.fromPriority // null), to_priority:(.toPriority // null),
       from_project:(.fromProject // null), to_project:(.toProject // null),
       from_parent:(.fromParent // null), to_parent:(.toParent // null),
       from_due_date:(.fromDueDate // null), to_due_date:(.toDueDate // null),
       description_updated:(.updatedDescription == true),
       description:$content.description,
       added_labels:((.addedLabels // []) | map({id:(.id // null),name})),
       removed_labels:((.removedLabels // []) | map({id:(.id // null),name}))}
      + (if $cutoff != "" and (.updatedAt // .createdAt) >= $cutoff then {bootstrap:true} else {} end)
    ' > "$record" || return 1
    publish_inbox "$key" "$record" || return 1
    history_hash_set "$id" "$hash" "$updated" || return 1
    record_event_count "$authority" "$issue"
  done < "$TMP_ROOT/history-rows.jsonl"
}

prepare_issue_heads() {
  if [ -e "$ISSUE_HEADS_FILE" ]; then
    [ -f "$ISSUE_HEADS_FILE" ] && [ ! -L "$ISSUE_HEADS_FILE" ] || return 1
    jq -e 'type == "object"' "$ISSUE_HEADS_FILE" >/dev/null 2>&1 || return 1
    cp "$ISSUE_HEADS_FILE" "$TMP_ROOT/issue-heads-before.json" || return 1
  else
    printf '{}\n' > "$TMP_ROOT/issue-heads-before.json"
  fi
  cp "$TMP_ROOT/issue-heads-before.json" "$TMP_ROOT/issue-heads-next.json"
}

issue_creation_known() {  # <issue>
  jq -e --arg issue "$1" '.[$issue] != null' "$TMP_ROOT/issue-heads-next.json" >/dev/null 2>&1
}

issue_creation_mark() {  # <issue>
  local next="$TMP_ROOT/issue-head-created.json"
  jq --arg issue "$1" '.[$issue]=((.[$issue] // {}) + {created_seen:true})' \
    "$TMP_ROOT/issue-heads-next.json" > "$next" || return 1
  mv -f -- "$next" "$TMP_ROOT/issue-heads-next.json"
}

derive_issue_snapshots() {  # <observed-at> <creation-cutoff>
  local observed=$1 row issue updated state description description_hash hash prior_hash prior_updated
  local key record next snapshot prior_snapshot changes kind ownership_acquired state_id assignee_id reconcile_status
  jq -c 'sort_by(.updatedAt, .identifier)[]' "$TMP_ROOT/issues.json" \
    > "$TMP_ROOT/issue-snapshot-rows.jsonl" || return 1
  while IFS= read -r row; do
    issue=$(printf '%s' "$row" | jq -r '.identifier // empty')
    updated=$(printf '%s' "$row" | jq -r '.updatedAt // empty')
    state=$(printf '%s' "$row" | jq -r '.state.name // "unknown"')
    description=$(printf '%s' "$row" | jq -r '.description // ""')
    [ -n "$issue" ] && [ -n "$updated" ] || continue
    snapshot=$(printf '%s' "$row" | jq -cS '{title:(.title // ""),description:(.description // ""),
      priority:(.priority // null),project:(.project // null),parent:(.parent // null),due_date:(.dueDate // null),
      state:(.state // null),assignee:(if .assignee == null then null else {id:.assignee.id} end),
      labels:((.labels.nodes // []) | map(.name) | sort)}') \
      || return 1
    hash=$(printf '%s' "$snapshot" | fm_linear_sha256) || return 1
    description_hash=$(printf '%s' "$description" | fm_linear_sha256) || return 1
    prior_hash=$(jq -r --arg issue "$issue" '.[$issue].snapshot_sha256 // empty' \
      "$TMP_ROOT/issue-heads-next.json") || return 1
    prior_updated=$(jq -r --arg issue "$issue" '.[$issue].updated_at // empty' \
      "$TMP_ROOT/issue-heads-next.json") || return 1
    prior_snapshot=$(jq -c --arg issue "$issue" '.[$issue].snapshot // null' \
      "$TMP_ROOT/issue-heads-next.json") || return 1
    if [ -n "$prior_hash" ] && [ "$hash" != "$prior_hash" ]; then
      changes=$(jq -n --argjson before "$prior_snapshot" --argjson after "$snapshot" \
          --arg issue "$issue" --arg prior "$prior_updated" --arg current "$updated" \
          --slurpfile history "$TMP_ROOT/history.json" '
          def description_target:
            try (.changes.description // .changes.descriptionMarkdown // .changes.descriptionText) catch null
            | if type == "array" then .[-1]
              elif type == "object" then (.to // .newValue // .new // null)
              elif type == "string" then .
              else null end;
          (reduce ($after | keys[]) as $key ({};
            if $before[$key] == $after[$key] then . else .[$key]=$after[$key] end)) as $delta
          | [($history[0][]
              | select(.issue == $issue
                and ($prior == "" or (.updatedAt // .createdAt) > $prior)
                and (.updatedAt // .createdAt) <= $current))]
            | sort_by((.updatedAt // .createdAt),.id) as $relevant
          | (reduce $relevant[] as $h ({};
              if $h.updatedDescription == true and ($h|description_target) != null
                then .description={present:true,value:($h|description_target)} else . end
              | if $h.fromTitle != null or $h.toTitle != null
                then .title={present:true,value:$h.toTitle} else . end
              | if $h.fromPriority != null or $h.toPriority != null
                then .priority={present:true,value:$h.toPriority} else . end
              | if $h.fromProject != null or $h.toProject != null
                then .project={present:true,value:$h.toProject} else . end
              | if $h.fromParent != null or $h.toParent != null
                then .parent={present:true,value:$h.toParent} else . end
              | if $h.fromDueDate != null or $h.toDueDate != null
                then .due_date={present:true,value:$h.toDueDate} else . end
              | if $h.fromState != null or $h.toState != null
                then .state={present:true,value:$h.toState} else . end
              | if $h.fromAssignee != null or $h.toAssignee != null
                then .assignee={present:true,
                  value:(if $h.toAssignee == null then null else {id:$h.toAssignee.id} end)} else . end
              | if ((($h.addedLabels // []) | length) + (($h.removedLabels // []) | length)) > 0 then
                  ((.labels.value // ($before.labels // []))
                    - (($h.removedLabels // []) | map(.name))
                    + (($h.addedLabels // []) | map(.name)) | unique | sort) as $labels
                  | .labels={present:true,value:$labels}
                else . end)) as $targets
          | reduce ($delta | keys[]) as $field ($delta;
              if ($targets[$field].present // false) and $targets[$field].value == $after[$field]
              then del(.[$field]) else . end)') || return 1
      if printf '%s' "$changes" | jq -e 'has("state") or has("assignee")' >/dev/null; then
        state_id=$(printf '%s' "$snapshot" | jq -r '.state.id // empty') || return 1
        assignee_id=$(printf '%s' "$snapshot" | jq -r '.assignee.id // empty') || return 1
        if reconcile_outbox_snapshot_board "$issue" "$updated" "$state_id" "$assignee_id"; then
          changes=$(printf '%s' "$changes" | jq 'del(.state,.assignee)') || return 1
        else
          reconcile_status=$?
          [ "$reconcile_status" -eq 1 ] || return 1
        fi
      fi
      if [ "$(printf '%s' "$changes" | jq -r 'length')" -gt 0 ]; then
        ownership_acquired=$(jq -n --argjson before "$prior_snapshot" --argjson after "$snapshot" '
          (($before.labels // []) | index("Firstmate")) == null
          and (($after.labels // []) | index("Firstmate")) != null') || return 1
        if [ "$(printf '%s' "$changes" | jq -r 'keys == ["description"]')" = true ]; then
          kind=description
          key="description-snapshot:$issue:$updated:$hash"
        elif [ "$(printf '%s' "$changes" | jq -r 'keys == ["labels"]')" = true ]; then
          kind=label
          key="label-snapshot:$issue:$updated:$hash"
        else
          kind='issue-change'
          key="issue-snapshot:$issue:$updated:$hash"
        fi
        record="$TMP_ROOT/inbox-issue-snapshot-$issue.json"
        jq -n --arg kind "$kind" --arg issue "$issue" --arg updated "$updated" \
          --arg observed "$observed" --arg hash "$hash" --arg description "$description" \
          --argjson changes "$changes" --argjson snapshot "$snapshot" \
          --argjson ownership_acquired "$ownership_acquired" '
          {kind:$kind,source:"issue-snapshot",issue:$issue,author:"unknown",author_id:null,
           authority:"unattributed",
           created_at:$updated,updated_at:$updated,observed_at:$observed,
           snapshot_sha256:$hash,changes:$changes}
          + (if $kind == "description" then {description:$description} else {} end)
          + (if $ownership_acquired then {ownership_acquired:true,labels:$snapshot.labels} else {} end)
        ' > "$record" || return 1
        publish_inbox "$key" "$record" || return 1
        record_event_count unattributed "$issue"
      fi
    fi
    next="$TMP_ROOT/issue-head-updated.json"
    jq --arg issue "$issue" --arg updated "$updated" --arg state "$state" --arg hash "$hash" \
      --arg description_hash "$description_hash" --argjson snapshot "$snapshot" '
      .[$issue]=((.[$issue] // {}) + {updated_at:$updated,state:$state,snapshot:$snapshot,
        snapshot_sha256:$hash,description_sha256:$description_hash})
    ' "$TMP_ROOT/issue-heads-next.json" > "$next" || return 1
    mv -f -- "$next" "$TMP_ROOT/issue-heads-next.json" || return 1
  done < "$TMP_ROOT/issue-snapshot-rows.jsonl"
  fm_linear_atomic_file "$ISSUE_HEADS_FILE" 600 < "$TMP_ROOT/issue-heads-next.json"
}

derive_issue_creation() {  # <observed-at> <creation-cutoff> <bootstrap-cutoff>
  local observed=$1 creation_cutoff=$2 bootstrap_cutoff=$3 row issue creator_id created key labels record should_wake authority row_cutoff
  jq -c 'sort_by(.createdAt, .identifier)[]' "$TMP_ROOT/issues.json" > "$TMP_ROOT/issue-rows.jsonl" || return 1
  while IFS= read -r row; do
    issue=$(printf '%s' "$row" | jq -r '.identifier // empty')
    creator_id=$(printf '%s' "$row" | jq -r '.creator.id // empty')
    created=$(printf '%s' "$row" | jq -r '.createdAt // empty')
    row_cutoff=$(printf '%s' "$row" | jq -r '._scan_threshold // empty')
    [ -n "$row_cutoff" ] || row_cutoff=$creation_cutoff
    [ -n "$issue" ] && [ -n "$created" ] || continue
    [ -z "$row_cutoff" ] || [[ "$created" > "$row_cutoff" || "$created" = "$row_cutoff" ]] || continue
    key="issue-created:$issue"
    if issue_creation_known "$issue"; then
      issue_creation_mark "$issue" || return 1
      continue
    fi
    labels=$(printf '%s' "$row" | jq -r '[.labels.nodes[].name] | join(",")')
    should_wake=0
    case ",$labels," in *,Firstmate,*) should_wake=1 ;; esac
    if { [ -n "$creator_id" ] && [ "$creator_id" = "$SELF_ID" ]; } || [ "$should_wake" -eq 0 ]; then
      issue_creation_mark "$issue" || return 1
      continue
    fi
    if [ "$creator_id" = "$FM_LINEAR_CAPTAIN_ID" ]; then
      authority=captain
    elif [ -n "$creator_id" ]; then
      authority=non-captain
    else
      authority=unattributed
    fi
    record="$TMP_ROOT/inbox-issue-$issue.json"
    printf '%s' "$row" | jq --arg observed "$observed" --arg cutoff "$bootstrap_cutoff" \
      --arg authority "$authority" '
      {kind:"issue-created", issue:.identifier, authority:$authority,
       author:(.creator.displayName // "unknown"),
       author_id:(.creator.id // null),
       created_at:.createdAt, updated_at:.updatedAt, observed_at:$observed,
       title:(.title // ""), description:(.description // ""),
       state:(.state.name // null), assignee:(.assignee // null),
       priority:(.priority // null), project:(.project // null), parent:(.parent // null),
       due_date:(.dueDate // null), labels:[.labels.nodes[].name]}
      + (if $cutoff != "" and .createdAt >= $cutoff then {bootstrap:true} else {} end)
    ' > "$record" || return 1
    publish_inbox "$key" "$record" || return 1
    issue_creation_mark "$issue" || return 1
    record_event_count "$authority" "$issue"
  done < "$TMP_ROOT/issue-rows.jsonl"
}

audit_invariants() {
  local row issue status updated assignee assignee_id role expected expected_id current next kept previous previous_status occurrence entry entry_id entry_hash
  local previous_head_status previous_head_updated mismatch_current mismatch_next entry_updated
  current="$TMP_ROOT/unknown-status-current.tsv"
  next="$TMP_ROOT/unknown-status-next.tsv"
  kept="$TMP_ROOT/unknown-status-acks-kept.tsv"
  mismatch_current="$TMP_ROOT/turn-mismatches-current.json"
  mismatch_next="$TMP_ROOT/turn-mismatches-next.json"
  if [ -e "$UNKNOWN_FILE" ]; then
    [ -f "$UNKNOWN_FILE" ] && [ ! -L "$UNKNOWN_FILE" ] || return 1
    awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3; next }
      NF == 2 { print $1 "\t" $2 "\tlegacy" }' "$UNKNOWN_FILE" > "$current" || return 1
  else
    : > "$current"
  fi
  if [ -e "$TURN_MISMATCH_FILE" ]; then
    [ -f "$TURN_MISMATCH_FILE" ] && [ ! -L "$TURN_MISMATCH_FILE" ] || return 1
    jq -e 'type == "array"' "$TURN_MISMATCH_FILE" >/dev/null 2>&1 || return 1
    cp "$TURN_MISMATCH_FILE" "$mismatch_current" || return 1
  else
    printf '[]\n' > "$mismatch_current"
  fi
  jq -c '.[]' "$TMP_ROOT/issues-audit.json" > "$TMP_ROOT/audit-rows.jsonl" || return 1
  while IFS= read -r row; do
    issue=$(printf '%s' "$row" | jq -r '.identifier // "unknown"')
    status=$(printf '%s' "$row" | jq -r '.state.name // "unknown"')
    updated=$(printf '%s' "$row" | jq -r '.updatedAt // "unknown"')
    assignee=$(printf '%s' "$row" | jq -r '.assignee.displayName // "unassigned"')
    assignee_id=$(printf '%s' "$row" | jq -r '.assignee.id // empty')
    previous_head_status=$(jq -r --arg issue "$issue" '.[$issue].state // empty' \
      "$TMP_ROOT/issue-heads-before.json") || return 1
    previous_head_updated=$(jq -r --arg issue "$issue" '.[$issue].updated_at // empty' \
      "$TMP_ROOT/issue-heads-before.json") || return 1
    previous=$(awk -F '\t' -v issue="$issue" '$1 == issue { print $2 "\t" $3; exit }' "$current")
    previous_status=${previous%%"$(printf '\t')"*}
    [ "$previous_status" != "$previous" ] || previous_status=
    awk -F '\t' -v issue="$issue" '$1 != issue' "$current" > "$next" || return 1
    mv -f -- "$next" "$current" || return 1
    jq --arg issue "$issue" '[.[] | select(.issue != $issue)]' "$mismatch_current" \
      > "$mismatch_next" || return 1
    mv -f -- "$mismatch_next" "$mismatch_current" || return 1
    if role=$(fm_linear_status_role "$status"); then
      if [ "$role" = captain ]; then
        expected=$CAPTAIN_NAME
        expected_id=$FM_LINEAR_CAPTAIN_ID
      else
        expected=$SELF_NAME
        expected_id=$FM_LINEAR_FIRSTMATE_ID
      fi
      if [ "$assignee_id" != "$expected_id" ]; then
        jq --arg issue "$issue" --arg status "$status" --arg assignee "$assignee" \
          --arg assignee_id "$assignee_id" --arg expected "$expected" \
          --arg expected_id "$expected_id" '
            . + [{issue:$issue,status:$status,assignee:$assignee,
                  assignee_id:(if $assignee_id == "" then null else $assignee_id end),
                  expected:$expected,expected_id:$expected_id}]
          ' "$mismatch_current" > "$mismatch_next" || return 1
        mv -f -- "$mismatch_next" "$mismatch_current" || return 1
      fi
    elif ! fm_linear_status_known_without_turn_marker "$status"; then
      entry=$(jq -c --arg issue "$issue" --arg status "$status" \
        --arg previous "$previous_head_updated" --arg current "$updated" '
        [.[]
          | select(.issue == $issue and (.fromState != null or .toState != null))
          | . + {_occurrence:(.updatedAt // .createdAt)}
          | select(($previous == "" or ._occurrence > $previous) and ._occurrence <= $current)]
        | sort_by(._occurrence, .id) | last
        | select(.toState.name == $status) // empty
      ' "$TMP_ROOT/history.json") || return 1
      entry_id=$(printf '%s' "$entry" | jq -r '.id // empty') || return 1
      if [ -n "$entry_id" ]; then
        entry_hash=$(awk -F '\t' -v id="$entry_id" '$1 == id { print $2; exit }' "$HISTORY_HEADS_FILE" 2>/dev/null)
        entry_updated=$(printf '%s' "$entry" | jq -r '._occurrence // empty') || return 1
        occurrence="history:$entry_id:${entry_updated:-unknown}:${entry_hash:-unknown}"
      elif [ "$previous_status" = "$status" ] \
        && [ "$previous_head_status" = "$status" ] \
        && [ "$previous_head_updated" = "$updated" ]; then
        occurrence=${previous#*"$(printf '\t')"}
      else
        occurrence="snapshot:$updated"
      fi
      printf '%s\t%s\t%s\n' "$issue" "$status" "$occurrence" >> "$current" || return 1
    fi
  done < "$TMP_ROOT/audit-rows.jsonl"
  jq -r '.[] | "linear: TURN-MARKER MISMATCH \(.issue) (\(.status) assigned to \(.assignee) [\(.assignee_id // "unassigned")], expected \(.expected) [\(.expected_id)])"' \
    "$mismatch_current"
  fm_linear_atomic_file "$TURN_MISMATCH_FILE" 600 < "$mismatch_current" || return 1
  while IFS="$(printf '\t')" read -r issue status occurrence; do
    [ -n "$issue" ] || continue
    if ! awk -F '\t' -v issue="$issue" -v status="$status" -v occurrence="$occurrence" \
      '$1 == issue && $2 == status && $3 == occurrence { found=1 } END { exit !found }' \
      "$UNKNOWN_ACK_FILE" 2>/dev/null; then
      printf 'linear: UNKNOWN STATUS %s (%s)\n' "$status" "$issue"
    fi
  done < "$current"
  fm_linear_atomic_file "$UNKNOWN_FILE" 600 < "$current" || return 1
  if [ -e "$UNKNOWN_ACK_FILE" ]; then
    [ -f "$UNKNOWN_ACK_FILE" ] && [ ! -L "$UNKNOWN_ACK_FILE" ] || return 1
    awk -F '\t' 'NR == FNR { current[$1 FS $2 FS $3]=1; next }
      current[$1 FS $2 FS $3] { print }' "$current" "$UNKNOWN_ACK_FILE" > "$kept" || return 1
    fm_linear_atomic_file "$UNKNOWN_ACK_FILE" 600 < "$kept" || return 1
  fi
}

announce_stale_pending() {
  local now captain_oldest=0 captain_issue=unknown captain_count=0 captain_unreadable=0
  local observation_oldest=0 observation_issue=unknown observation_count=0 observation_unreadable=0
  local file event_at epoch age authority
  now=${FM_LINEAR_NOW_EPOCH:-$(date +%s)}
  [ -d "$INBOX" ] || return 0
  for file in "$INBOX"/*.json; do
    [ -f "$file" ] || continue
    [ -e "${file%.json}.handled" ] && continue
    authority=$(jq -r --arg captain "$FM_LINEAR_CAPTAIN_ID" \
      '.authority // (if .author_id == $captain then "captain" else "unattributed" end)' \
      "$file" 2>/dev/null)
    if [ "$authority" = captain ]; then
      captain_count=$((captain_count + 1))
    else
      observation_count=$((observation_count + 1))
    fi
    event_at=$(jq -r '.updated_at // .created_at // empty' "$file" 2>/dev/null)
    epoch=$(fm_linear_epoch "$event_at" 2>/dev/null || true)
    case "$epoch" in
      ''|*[!0-9]*)
        if [ "$authority" = captain ]; then captain_unreadable=1; else observation_unreadable=1; fi
        continue
        ;;
    esac
    if [ "$authority" = captain ]; then
      if [ "$captain_oldest" -eq 0 ] || [ "$epoch" -lt "$captain_oldest" ]; then
        captain_oldest=$epoch
        captain_issue=$(jq -r '.issue // "unknown"' "$file" 2>/dev/null)
      fi
    else
      if [ "$observation_oldest" -eq 0 ] || [ "$epoch" -lt "$observation_oldest" ]; then
        observation_oldest=$epoch
        observation_issue=$(jq -r '.issue // "unknown"' "$file" 2>/dev/null)
      fi
    fi
  done
  [ "$captain_unreadable" -eq 0 ] || printf 'linear: UNHANDLED captain inputs have unreadable timestamps\n'
  [ "$observation_unreadable" -eq 0 ] \
    || printf 'linear: UNHANDLED non-authoritative observations have unreadable timestamps\n'
  if [ "$captain_count" -gt 0 ]; then
    if [ "$captain_oldest" -gt 0 ]; then age=$((now - captain_oldest)); else age=0; fi
  else
    age=0
  fi
  if [ "$captain_count" -gt 0 ] && [ "$age" -ge "${FM_LINEAR_PENDING_ALARM_SECONDS:-300}" ]; then
    printf 'linear: %s UNHANDLED captain inputs, oldest %sm (%s)\n' \
      "$captain_count" "$((age / 60))" "$captain_issue"
  fi
  if [ "$observation_count" -gt 0 ]; then
    if [ "$observation_oldest" -gt 0 ]; then age=$((now - observation_oldest)); else age=0; fi
  else
    age=0
  fi
  if [ "$observation_count" -gt 0 ] && [ "$age" -ge "${FM_LINEAR_PENDING_ALARM_SECONDS:-300}" ]; then
    printf 'linear: %s UNHANDLED non-authoritative observations, oldest %sm (%s)\n' \
      "$observation_count" "$((age / 60))" "$observation_issue"
  fi
}

announce_outbox() {
  local now file created epoch age issue sweeps needs_board needs_comment missing
  now=${FM_LINEAR_NOW_EPOCH:-$(date +%s)}
  [ -d "$OUTBOX" ] || return 0
  for file in "$OUTBOX"/*.json; do
    [ -f "$file" ] || continue
    created=$(jq -r '.created_at // empty' "$file" 2>/dev/null)
    epoch=$(fm_linear_epoch "$created" 2>/dev/null || true)
    case "$epoch" in ''|*[!0-9]*)
      printf 'linear: UNFINISHED write has unreadable journal %s\n' "${file##*/}"
      continue
      ;;
    esac
    age=$((now - epoch))
    if [ "$age" -ge "${FM_LINEAR_OUTBOX_ALARM_SECONDS:-300}" ]; then
      issue=$(jq -r '.issue // "unknown"' "$file" 2>/dev/null)
      printf 'linear: UNFINISHED write to %s, %sm\n' "$issue" "$((age / 60))"
    fi
  done
  for file in "$OUTBOX"/*.done; do
    [ -f "$file" ] || continue
    needs_board=$(jq -r 'if (.target_state // "") == "" then "false" else "true" end' "$file" 2>/dev/null)
    needs_comment=$(jq -r 'if (.comment_id // "") == "" then "false" else "true" end' "$file" 2>/dev/null)
    missing=0
    [ "$needs_board" != true ] || [ -e "${file%.done}.board-observed" ] || missing=1
    [ "$needs_comment" != true ] || [ -e "${file%.done}.comment-observed" ] || missing=1
    [ "$missing" -eq 1 ] || continue
    sweeps_file="$file.unobserved-sweeps"
    sweeps=$(cat "$sweeps_file" 2>/dev/null || printf 0)
    case "$sweeps" in ''|*[!0-9]*) sweeps=0 ;; esac
    sweeps=$((sweeps + 1))
    printf '%s\n' "$sweeps" | fm_linear_atomic_file "$sweeps_file" 600 2>/dev/null || true
    if [ "$sweeps" -ge "${FM_LINEAR_WRITE_OBSERVE_SWEEPS:-3}" ]; then
      issue=$(jq -r '.issue // "unknown"' "$file" 2>/dev/null)
      printf 'linear: WRITE NOT OBSERVED %s\n' "$issue"
    fi
  done
}

prune_retained_state() {
  local file
  [ -d "$INBOX" ] || return 0
  find "$INBOX" -type f -name '*.handled' -mtime +14 -print 2>/dev/null | while IFS= read -r file; do
    rm -f -- "$file" "${file%.handled}.json" 2>/dev/null || true
  done
  [ -d "$OUTBOX" ] || return 0
  find "$OUTBOX" -type f -name '*.done' -mtime +7 -print 2>/dev/null | while IFS= read -r file; do
    rm -f -- "$file" "$file.unobserved-sweeps" \
      "${file%.done}.comment-observed" "${file%.done}.board-observed" 2>/dev/null || true
  done
}

timing_mark() {  # <label>
  [ "${FM_LINEAR_TIMING:-0}" = 1 ] || return 0
  printf 'fm-linear-timing %s %s\n' "$1" "$(date +%s)" >&2
}

acknowledge_unknown_status() {  # <issue> <status>
  local issue=$1 status=$2 lock_status next occurrence
  case "$issue" in BIG-[0-9]*) ;; *) printf 'linear: invalid issue identifier: %s\n' "$issue" >&2; return 2 ;; esac
  case "$status" in *"$(printf '\t')"*|*$'\n'*) printf 'linear: invalid status name\n' >&2; return 2 ;; esac
  fm_linear_private_dir "$STATE" || return 1
  fm_linear_lock_acquire "$LOCK"
  lock_status=$?
  case "$lock_status" in 0) LOCK_HELD=1 ;; 1) printf 'linear: POLL BUSY: another ledger writer holds the lock\n' >&2; return 1 ;; *) return 1 ;; esac
  [ -f "$UNKNOWN_FILE" ] && [ ! -L "$UNKNOWN_FILE" ] || {
    printf 'linear: unknown status occurrence is not current: %s (%s)\n' "$status" "$issue" >&2
    return 1
  }
  occurrence=$(awk -F '\t' -v issue="$issue" -v status="$status" \
    '$1 == issue && $2 == status { print $3; exit }' "$UNKNOWN_FILE")
  [ -n "$occurrence" ] || {
    printf 'linear: unknown status occurrence is not current: %s (%s)\n' "$status" "$issue" >&2
    return 1
  }
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-ack.XXXXXX") || return 1
  next="$TMP_ROOT/unknown-status-acks.tsv"
  if [ -e "$UNKNOWN_ACK_FILE" ]; then
    [ -f "$UNKNOWN_ACK_FILE" ] && [ ! -L "$UNKNOWN_ACK_FILE" ] || return 1
    awk -F '\t' -v issue="$issue" -v status="$status" \
      '!($1 == issue && $2 == status)' "$UNKNOWN_ACK_FILE" > "$next" || return 1
  else
    : > "$next"
  fi
  printf '%s\t%s\t%s\n' "$issue" "$status" "$occurrence" >> "$next" || return 1
  fm_linear_atomic_file "$UNKNOWN_ACK_FILE" 600 < "$next" || return 1
  printf 'linear: acknowledged unknown status %s (%s)\n' "$status" "$issue"
}

acknowledge_event() {  # <inbox-filename.json>
  local name=$1 event marker lock_status
  case "$name" in
    */*|''|.*|*.handled|*[!A-Za-z0-9._-]*|*.json.json) 
      printf 'linear: invalid inbox event filename: %s\n' "$name" >&2
      return 2
      ;;
    *.json) ;;
    *) printf 'linear: invalid inbox event filename: %s\n' "$name" >&2; return 2 ;;
  esac
  fm_linear_private_dir "$STATE" || return 1
  fm_linear_private_dir "$INBOX" || return 1
  fm_linear_lock_acquire "$LOCK"
  lock_status=$?
  case "$lock_status" in 0) LOCK_HELD=1 ;; 1) printf 'linear: POLL BUSY: another ledger writer holds the lock\n' >&2; return 1 ;; *) return 1 ;; esac
  event="$INBOX/$name"
  marker="${event%.json}.handled"
  [ -f "$event" ] && [ ! -L "$event" ] || {
    printf 'linear: inbox event is missing or unsafe: %s\n' "$name" >&2
    return 1
  }
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || {
      printf 'linear: handled marker is unsafe: %s\n' "${marker##*/}" >&2
      return 1
    }
  else
    fm_linear_atomic_file "$marker" 600 < /dev/null || return 1
  fi
  printf 'linear: acknowledged inbox event %s\n' "$name"
}

main() {
  local comments_cursor issues_cursor comments_cursor_stored issues_cursor_stored
  local bootstrap_cutoff creation_cutoff comments_max issues_max observed cursor_tmp lock_status
  local next_comments_cursor next_issues_cursor
  fm_linear_private_dir "$STATE" || {
    printf 'linear: POLL STATE FAILURE: state directory unavailable\n'
    return 1
  }
  fm_linear_private_dir "$INBOX" || {
    printf 'linear: POLL STATE FAILURE: inbox unavailable\n'
    return 1
  }
  fm_linear_lock_acquire "$LOCK"
  lock_status=$?
  case "$lock_status" in
    0) ;;
    1) printf 'linear: POLL BUSY: another ledger writer holds the lock\n'; return 1 ;;
    *) printf 'linear: POLL LOCK FAILURE: lock state is unsafe\n'; return 1 ;;
  esac
  LOCK_HELD=1
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-poll.XXXXXX") || {
    record_failure "cannot create poll workspace"
    return 1
  }
  if ! command -v jq >/dev/null 2>&1; then
    record_failure "missing jq"
    return 1
  fi
  if ! fm_linear_time_self_check; then
    record_failure "Linear UTC timestamp conversion self-check failed"
    return 1
  fi
  if ! fm_linear_load_key; then
    record_failure "missing LINEAR_API_KEY in $FM_HOME/.env"
    return 1
  fi
  if ! fm_linear_load_identity_ids; then
    record_failure "$FM_LINEAR_IDENTITY_ERROR"
    return 1
  fi
  SELF_ID=$FM_LINEAR_FIRSTMATE_ID
  prepare_issue_heads || {
    record_failure "cannot read Linear issue snapshot state"
    return 1
  }

  comments_cursor_stored=$(cursor_get comments_updated_at)
  issues_cursor_stored=$(cursor_get issues_updated_at)
  comments_cursor=$comments_cursor_stored
  issues_cursor=$issues_cursor_stored
  [ -z "$comments_cursor" ] || comments_cursor=$(fm_linear_normalize_timestamp "$comments_cursor") || {
    record_failure "invalid comments cursor"
    return 1
  }
  [ -z "$issues_cursor" ] || issues_cursor=$(fm_linear_normalize_timestamp "$issues_cursor") || {
    record_failure "invalid issues cursor"
    return 1
  }
  bootstrap_cutoff=$(bootstrap_horizon "$comments_cursor" "$issues_cursor") || {
    record_failure "cannot persist bootstrap horizon"
    return 1
  }

  if ! bootstrap_comment_heads "$bootstrap_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-comment-head bootstrap failed}"
    return 1
  fi
  timing_mark comment-heads-bootstrapped
  if ! fetch_comments "$comments_cursor" "$bootstrap_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-comments fetch failed}"
    return 1
  fi
  timing_mark comments-fetched
  if ! fetch_issues "$issues_cursor" "$bootstrap_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-issues fetch failed}"
    return 1
  fi
  timing_mark issues-fetched
  if ! reconcile_fetched_outbox_boards; then
    record_failure "${FM_LINEAR_API_ERROR:-cannot reconcile Linear outbox observations}"
    return 1
  fi

  comments_max=$(jq -r '[.[].updatedAt] | max // empty' "$TMP_ROOT/comments.json")
  issues_max=$(jq -r '[.[].updatedAt] | max // empty' "$TMP_ROOT/issues.json")
  observed=$(printf '%s\n%s\n' "$comments_max" "$issues_max" | sed '/^$/d' | LC_ALL=C sort | tail -n 1)
  if [ -n "$issues_cursor" ]; then
    creation_cutoff=$(fm_linear_overlap_timestamp "$issues_cursor") || {
      record_failure "cannot calculate issue creation overlap"
      return 1
    }
    creation_cutoff=$(fm_linear_normalize_timestamp "$creation_cutoff") || return 1
  else
    creation_cutoff=$bootstrap_cutoff
  fi

  if ! derive_comments "$observed" "$bootstrap_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-cannot persist Linear event ledger}"
    return 1
  fi
  timing_mark comments-derived
  if ! derive_history "$observed" "$creation_cutoff" "$bootstrap_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-cannot persist Linear event ledger}"
    return 1
  fi
  timing_mark history-derived
  if ! derive_issue_creation "$observed" "$creation_cutoff" "$bootstrap_cutoff"; then
    record_failure "cannot persist Linear event ledger"
    return 1
  fi
  if ! derive_issue_snapshots "$observed" "$creation_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-cannot persist Linear issue snapshots}"
    return 1
  fi
  timing_mark issues-derived
  if ! audit_invariants; then
    record_failure "cannot persist Linear invariant state"
    return 1
  fi

  if [ "$COMMENT_SCAN_PENDING" -eq 1 ]; then
    next_comments_cursor=${comments_cursor_stored:-$bootstrap_cutoff}
  else
    next_comments_cursor=$(timestamp_max "${comments_cursor_stored:-$bootstrap_cutoff}" "$comments_max")
  fi
  next_issues_cursor=$(timestamp_max "${issues_cursor_stored:-$bootstrap_cutoff}" "$issues_max")
  if [ -n "$next_comments_cursor" ] && [ -n "$next_issues_cursor" ]; then
    cursor_tmp="$TMP_ROOT/cursor"
    {
      printf 'comments_updated_at=%s\n' "$next_comments_cursor"
      printf 'issues_updated_at=%s\n' "$next_issues_cursor"
    } > "$cursor_tmp"
    fm_linear_atomic_file "$CURSOR_FILE" 600 < "$cursor_tmp" || {
      record_failure "cannot publish Linear cursor"
      return 1
    }
    rm -f -- "$BOOTSTRAP_HORIZON_FILE" 2>/dev/null || true
  fi

  record_success "$observed" || {
    printf 'linear: POLL STATE FAILURE: cannot persist success health\n'
    return 1
  }
  announce_stale_pending
  announce_outbox
  prune_retained_state
  if [ "$NEW_EVENTS" -gt 0 ]; then
    printf 'linear: %s captain input(s) pending:%s\n' "$NEW_EVENTS" "$NEW_ISSUES"
  fi
  if [ "$NEW_OBSERVATIONS" -gt 0 ]; then
    printf 'linear: %s non-authoritative observation(s) pending:%s\n' \
      "$NEW_OBSERVATIONS" "$NEW_OBSERVATION_ISSUES"
  fi
}

run_bounded_poll() {
  local seconds watcher_seconds output status=0
  seconds=${FM_LINEAR_POLL_DEADLINE_SECONDS:-25}
  case "$seconds" in ''|*[!0-9]*|0) seconds=25 ;; esac
  [ "$seconds" -le 25 ] || seconds=25
  watcher_seconds=${FM_CHECK_TIMEOUT:-30}
  case "$watcher_seconds" in ''|*[!0-9]*|0|1) watcher_seconds=30 ;; esac
  [ "$seconds" -lt "$watcher_seconds" ] || seconds=$((watcher_seconds - 1))
  output=$(mktemp "${TMPDIR:-/tmp}/fm-linear-poll-output.XXXXXX") || {
    record_failure "cannot create bounded poll output"
    return 1
  }
  if fm_run_timed "$seconds" env FM_LINEAR_POLL_CHILD=1 "$0" > "$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  cat "$output"
  if [ "$status" -eq 124 ]; then
    record_failure "complete poll exceeded ${seconds}s deadline"
  elif [ "$status" -ne 0 ] && ! grep -q '^linear:' "$output"; then
    record_failure "poll exited with status $status"
  fi
  rm -f -- "$output"
  return "$status"
}

case "${1:-}" in
  '')
    if [ "${FM_LINEAR_POLL_CHILD:-0}" = 1 ]; then
      main
    else
      run_bounded_poll
    fi
    ;;
  acknowledge-unknown-status)
    [ "$#" -eq 3 ] || { printf 'usage: fm-linear-poll.sh acknowledge-unknown-status <BIG-n> <status>\n' >&2; exit 2; }
    acknowledge_unknown_status "$2" "$3"
    ;;
  acknowledge)
    [ "$#" -eq 2 ] || { printf 'usage: fm-linear-poll.sh acknowledge <inbox-filename.json>\n' >&2; exit 2; }
    acknowledge_event "$2"
    ;;
  *) printf 'usage: fm-linear-poll.sh [acknowledge <inbox-filename.json> | acknowledge-unknown-status <BIG-n> <status>]\n' >&2; exit 2 ;;
esac
