#!/usr/bin/env bash
# Poll Linear into a durable, identity-attributed event ledger.
# Usage:
#   fm-linear-poll.sh
#   fm-linear-poll.sh acknowledge-unknown-status <BIG-n> <status>
#
# Captain-authored events are atomically written under state/linear-inbox before
# their dedupe keys are recorded and before either server-timestamp cursor moves.
# Repeated and rewound reads are therefore idempotent, while comment transitions
# compare against the latest body hash and retain a distinct server-timestamp key.
#
# Set FM_LINEAR_FIXTURE_DIR to replace HTTP with lexically ordered canned GraphQL
# responses consumed in request order.
# Set FM_LINEAR_FIXTURE_LOG to record each fixture-backed request for tests.
# Set FM_LINEAR_TIMING=1 to print phase timestamps to stderr for diagnostics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

CURSOR_FILE="$STATE/.linear-cursor"
SEEN_FILE="$STATE/.linear-seen.tsv"
COMMENT_HEADS_FILE="$STATE/.linear-comment-heads.tsv"
HEALTH_FILE="$STATE/.linear-poll-health"
ERROR_FILE="$STATE/.linear-poll-error"
UNKNOWN_FILE="$STATE/.linear-unknown-status.tsv"
UNKNOWN_ACK_FILE="$STATE/.linear-unknown-status-acks.tsv"
INBOX="$STATE/linear-inbox"
OUTBOX="$STATE/linear-outbox"
LOCK="$STATE/.linear-poll-lock"
FM_LINEAR_FIXTURE_INDEX=0
FM_LINEAR_API_ERROR=
FM_LINEAR_KEY=
TMP_ROOT=
LOCK_HELD=0
NEW_EVENTS=0
NEW_ISSUES=
SEEN_KEYS=
SELF_NAME=${FM_LINEAR_SELF_NAME:-josh.padnickfirstmate}
SELF_ID=${FM_LINEAR_SELF_ID:-}
CAPTAIN_NAME=${FM_LINEAR_CAPTAIN_NAME:-josh.padnick}

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

seen_has() {  # <dedupe-key>
  local key=$1 needle
  printf -v needle '\n%s\n' "$key"
  case "$SEEN_KEYS" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

seen_append() {  # <dedupe-key> <observed-at>
  local key=$1 observed=$2
  if [ ! -e "$SEEN_FILE" ]; then
    (umask 077; : > "$SEEN_FILE") || return 1
    chmod 0600 "$SEEN_FILE" || return 1
  fi
  [ -f "$SEEN_FILE" ] && [ ! -L "$SEEN_FILE" ] || return 1
  printf '%s\t%s\n' "$key" "$observed" >> "$SEEN_FILE"
  SEEN_KEYS="${SEEN_KEYS}${key}
"
}

load_seen_keys() {
  local key _
  SEEN_KEYS='
'
  [ -f "$SEEN_FILE" ] || return 0
  [ ! -L "$SEEN_FILE" ] || return 1
  while IFS="$(printf '\t')" read -r key _; do
    [ -n "$key" ] || continue
    SEEN_KEYS="${SEEN_KEYS}${key}
"
  done < "$SEEN_FILE"
}

comment_hash_current() {  # <comment-id> <body-hash>
  local id=$1 hash=$2
  awk -F '\t' -v id="$id" -v hash="$hash" \
    '$1 == id && $2 == hash { found=1 } END { exit !found }' \
    "$COMMENT_HEADS_FILE" 2>/dev/null
}

comment_hash_set() {  # <comment-id> <body-hash> <observed-at>
  local id=$1 hash=$2 observed=$3 next="$TMP_ROOT/comment-heads-next.tsv"
  if [ -e "$COMMENT_HEADS_FILE" ]; then
    [ -f "$COMMENT_HEADS_FILE" ] && [ ! -L "$COMMENT_HEADS_FILE" ] || return 1
    awk -F '\t' -v id="$id" '$1 != id' "$COMMENT_HEADS_FILE" > "$next" || return 1
  else
    : > "$next"
  fi
  printf '%s\t%s\t%s\n' "$id" "$hash" "$observed" >> "$next" || return 1
  fm_linear_atomic_file "$COMMENT_HEADS_FILE" 600 < "$next"
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

fetch_comments() {  # <cursor>
  local cursor=$1 after='' since='' payload response page has_next end_cursor nodes viewer_id viewer_name query
  page=0
  : > "$TMP_ROOT/comments.json"
  printf '[]\n' > "$TMP_ROOT/comments.json"
  if [ -n "$cursor" ]; then
    since=$(fm_linear_overlap_timestamp "$cursor") || {
      FM_LINEAR_API_ERROR="invalid comments cursor"
      return 1
    }
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
      query='query($after:String){viewer{id displayName} comments(first:50,after:$after,orderBy:updatedAt,filter:{updatedAt:{gte:"'"$since"'"}}){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt body user{id displayName} issue{identifier} parent{id}}}}'
    else
      # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
      query='query($after:String){viewer{id displayName} comments(first:50,after:$after,orderBy:updatedAt){pageInfo{hasNextPage endCursor} nodes{id createdAt updatedAt body user{id displayName} issue{identifier} parent{id}}}}'
    fi
    jq -n --arg query "$query" --arg after "$after" \
      '{query:$query,variables:{after:(if $after == "" then null else $after end)}}' > "$payload" || return 1
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
    jq '.data.comments.nodes' "$response" > "$nodes" || return 1
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
        | . + {issue:$issue.identifier}]' "$response" > "$nodes" || return 1
  json_array_append "$TMP_ROOT/history.json" "$nodes"
}

fetch_more_history() {  # <issue-id> <after>
  local issue=$1 after=$2 page=0 payload response nodes has_next end_cursor query
  # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
  query='query($id:String!,$after:String){issue(id:$id){history(first:10,after:$after){pageInfo{hasNextPage endCursor} nodes{id createdAt actor{id displayName} fromState{name} toState{name} fromAssignee{id displayName} toAssignee{id displayName} updatedDescription addedLabels{name} removedLabels{name}}}}}'
  while :; do
    page=$((page + 1))
    [ "$page" -le "${FM_LINEAR_MAX_HISTORY_PAGES:-100}" ] || {
      FM_LINEAR_API_ERROR="history pagination exceeded limit for $issue"
      return 1
    }
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
    jq --arg issue "$issue" '[.data.issue.history.nodes[] | . + {issue:$issue}]' \
      "$response" > "$nodes" || return 1
    json_array_append "$TMP_ROOT/history.json" "$nodes" || return 1
    has_next=$(jq -r '.data.issue.history.pageInfo.hasNextPage // false' "$response")
    [ "$has_next" = true ] || break
    end_cursor=$(jq -r '.data.issue.history.pageInfo.endCursor // empty' "$response")
    [ -n "$end_cursor" ] || {
      FM_LINEAR_API_ERROR="history pagination omitted endCursor for $issue"
      return 1
    }
    after=$end_cursor
  done
}

fetch_issues() {  # <cursor> <bootstrap-cutoff>
  local cursor=$1 bootstrap_cutoff=$2 after='' since='' payload response page has_next end_cursor nodes query
  local history_list issue history_after threshold
  printf '[]\n' > "$TMP_ROOT/issues.json"
  printf '[]\n' > "$TMP_ROOT/history.json"
  if [ -n "$cursor" ]; then
    since=$(fm_linear_overlap_timestamp "$cursor") || {
      FM_LINEAR_API_ERROR="invalid issues cursor"
      return 1
    }
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
      query='query($after:String){issues(first:50,after:$after,orderBy:updatedAt,filter:{team:{key:{eq:"BIG"}},updatedAt:{gte:"'"$since"'"}}){pageInfo{hasNextPage endCursor} nodes{identifier title description updatedAt createdAt state{name} assignee{id displayName} creator{id displayName} labels{nodes{name}} history(first:10){pageInfo{hasNextPage endCursor} nodes{id createdAt actor{id displayName} fromState{name} toState{name} fromAssignee{id displayName} toAssignee{id displayName} updatedDescription addedLabels{name} removedLabels{name}}}}}}'
    else
      # shellcheck disable=SC2016 # GraphQL variables use literal dollar signs.
      query='query($after:String){issues(first:50,after:$after,orderBy:updatedAt,filter:{team:{key:{eq:"BIG"}}}){pageInfo{hasNextPage endCursor} nodes{identifier title description updatedAt createdAt state{name} assignee{id displayName} creator{id displayName} labels{nodes{name}} history(first:10){pageInfo{hasNextPage endCursor} nodes{id createdAt actor{id displayName} fromState{name} toState{name} fromAssignee{id displayName} toAssignee{id displayName} updatedDescription addedLabels{name} removedLabels{name}}}}}}'
    fi
    jq -n --arg query "$query" --arg after "$after" \
      '{query:$query,variables:{after:(if $after == "" then null else $after end)}}' > "$payload" || return 1
    api issues "$payload" "$response" || return 1
    jq -e '.data.issues.nodes | type == "array"' "$response" >/dev/null 2>&1 || {
      FM_LINEAR_API_ERROR="malformed issues response"
      return 1
    }
    nodes="$TMP_ROOT/issues-nodes-$page.json"
    jq '.data.issues.nodes' "$response" > "$nodes" || return 1
    json_array_append "$TMP_ROOT/issues.json" "$nodes" || return 1
    append_initial_histories "$response" "$page" || return 1
    threshold=${cursor:-$bootstrap_cutoff}
    jq -r --arg threshold "$threshold" '
      .data.issues.nodes[]
      | select(.history.pageInfo.hasNextPage == true)
      | (.history.nodes | length) as $count
      | ([.history.nodes[].createdAt] | min // "") as $oldest
      | select($count == 10 and ($threshold == "" or $oldest >= $threshold))
      | [.identifier, (.history.pageInfo.endCursor // ""), $oldest, ($count|tostring)]
      | @tsv
    ' "$response" >> "$history_list" || return 1
    has_next=$(jq -r '.data.issues.pageInfo.hasNextPage // false' "$response")
    [ "$has_next" = true ] || break
    end_cursor=$(jq -r '.data.issues.pageInfo.endCursor // empty' "$response")
    [ -n "$end_cursor" ] || {
      FM_LINEAR_API_ERROR="issues pagination omitted endCursor"
      return 1
    }
    after=$end_cursor
  done
  while IFS="$(printf '\t')" read -r issue history_after _; do
    [ -n "$issue" ] || continue
    [ -n "$history_after" ] || {
      FM_LINEAR_API_ERROR="history pagination omitted endCursor for $issue"
      return 1
    }
    fetch_more_history "$issue" "$history_after" || return 1
  done < "$history_list"
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

mark_outbox_comment_observed() {  # <comment-id>
  local comment_id=$1 journal marker
  [ -d "$OUTBOX" ] || return 0
  for journal in "$OUTBOX"/*.done; do
    [ -f "$journal" ] || continue
    [ "$(jq -r '.comment_id // empty' "$journal" 2>/dev/null)" = "$comment_id" ] || continue
    marker="${journal%.*}.comment-observed"
    [ -e "$marker" ] || (umask 077; : > "$marker") 2>/dev/null || true
  done
}

mark_outbox_board_observed() {  # <issue> <to-state> <to-assignee-id>
  local issue=$1 to_state=$2 to_assignee_id=$3 journal target_state expected_assignee_id marker
  [ -d "$OUTBOX" ] || return 0
  for journal in "$OUTBOX"/*.done; do
    [ -f "$journal" ] || continue
    [ "$(jq -r '.issue // empty' "$journal" 2>/dev/null)" = "$issue" ] || continue
    target_state=$(jq -r '.target_state // empty' "$journal" 2>/dev/null)
    [ -n "$target_state" ] || continue
    expected_assignee_id=$(jq -r '.assignee_id // empty' "$journal" 2>/dev/null)
    [ "$to_state" = "$target_state" ] && [ "$to_assignee_id" = "$expected_assignee_id" ] || continue
    marker="${journal%.*}.board-observed"
    [ -e "$marker" ] || (umask 077; : > "$marker") 2>/dev/null || true
  done
}

derive_comments() {  # <observed-at> <bootstrap-cutoff>
  local observed=$1 bootstrap_cutoff=$2 id body_b64 body_file author_id author issue parent created updated hash key record
  jq -r 'sort_by(.updatedAt, .id)[]
    | [(.id // "__FM_LINEAR_EMPTY__"), ("b:" + ((.body // "") | @base64)),
       (.user.id // "__FM_LINEAR_EMPTY__"), (.user.displayName // "unknown"),
       (.issue.identifier // "unknown"), (.parent.id // "__FM_LINEAR_EMPTY__"),
       (.createdAt // "__FM_LINEAR_EMPTY__"), (.updatedAt // "__FM_LINEAR_EMPTY__")]
    | @tsv
  ' "$TMP_ROOT/comments.json" > "$TMP_ROOT/comment-rows.tsv" || return 1
  while IFS="$(printf '\t')" read -r id body_b64 author_id author issue parent created updated; do
    [ "$id" != __FM_LINEAR_EMPTY__ ] || id=
    body_b64=${body_b64#b:}
    [ "$author_id" != __FM_LINEAR_EMPTY__ ] || author_id=
    [ "$parent" != __FM_LINEAR_EMPTY__ ] || parent=
    [ "$created" != __FM_LINEAR_EMPTY__ ] || created=
    [ "$updated" != __FM_LINEAR_EMPTY__ ] || updated=
    [ -n "$id" ] && [ -n "$updated" ] || return 1
    hash=$(printf '%s' "$body_b64" | base64 --decode | fm_linear_sha256) || return 1
    if comment_hash_current "$id" "$hash"; then
      [ -z "$author_id" ] || [ "$author_id" != "$SELF_ID" ] || mark_outbox_comment_observed "$id"
      continue
    fi
    key="comment:$id:$updated:$hash"
    if [ -n "$bootstrap_cutoff" ] && [[ "$updated" < "$bootstrap_cutoff" ]]; then
      comment_hash_set "$id" "$hash" "$observed" || return 1
      continue
    fi
    if [ -n "$author_id" ] && [ "$author_id" = "$SELF_ID" ]; then
      comment_hash_set "$id" "$hash" "$observed" || return 1
      mark_outbox_comment_observed "$id"
      continue
    fi
    record="$TMP_ROOT/inbox-comment-$id.json"
    body_file="$TMP_ROOT/comment-body-$id"
    printf '%s' "$body_b64" | base64 --decode > "$body_file" || return 1
    jq -n --arg issue "$issue" --arg id "$id" \
      --arg parent "$parent" --arg author "$author" --arg created "$created" \
      --arg author_id "$author_id" \
      --arg updated "$updated" --arg hash "$hash" --rawfile body "$body_file" \
      --arg observed "$observed" --arg cutoff "$bootstrap_cutoff" '
        {kind:"comment", issue:$issue, comment_id:$id,
         parent_id:(if $parent == "" then null else $parent end), author:$author,
         author_id:(if $author_id == "" then null else $author_id end),
         created_at:$created, updated_at:$updated, body_sha256:$hash, body:$body,
         excerpt:($body[0:300]), observed_at:$observed}
        + (if $cutoff != "" and $updated >= $cutoff then {bootstrap:true} else {} end)
      ' > "$record" || return 1
    publish_inbox "$key" "$record" || return 1
    comment_hash_set "$id" "$hash" "$observed" || return 1
    NEW_EVENTS=$((NEW_EVENTS + 1))
    note_issue "$issue"
  done < "$TMP_ROOT/comment-rows.tsv"
}

derive_history() {  # <observed-at> <bootstrap-cutoff>
  local observed=$1 bootstrap_cutoff=$2 id actor_id actor issue created key kind record has_board has_description has_labels
  local to_state to_assignee_id to_assignee from_state from_assignee added_b64 removed_b64
  jq -r 'sort_by(.createdAt, .id)[]
    | [(.id // "__FM_LINEAR_EMPTY__"), (.actor.id // "__FM_LINEAR_EMPTY__"),
       (.actor.displayName // "unknown"), (.issue // "unknown"),
       (.createdAt // "__FM_LINEAR_EMPTY__"),
       ((.fromState != null or .toState != null or .fromAssignee != null or .toAssignee != null) | tostring),
       ((.updatedDescription != null) | tostring),
       ((((.addedLabels // []) | length) + ((.removedLabels // []) | length) > 0) | tostring),
       (.toState.name // "__FM_LINEAR_EMPTY__"),
       (.toAssignee.id // "__FM_LINEAR_EMPTY__"),
       (.toAssignee.displayName // "__FM_LINEAR_EMPTY__"),
       (.fromState.name // "__FM_LINEAR_EMPTY__"),
       (.fromAssignee.displayName // "__FM_LINEAR_EMPTY__"),
       ((.addedLabels // [] | map(.name) | tojson) | @base64),
       ((.removedLabels // [] | map(.name) | tojson) | @base64)]
    | @tsv
  ' "$TMP_ROOT/history.json" > "$TMP_ROOT/history-rows.tsv" || return 1
  while IFS="$(printf '\t')" read -r id actor_id actor issue created has_board has_description has_labels \
    to_state to_assignee_id to_assignee from_state from_assignee added_b64 removed_b64; do
    [ "$id" != __FM_LINEAR_EMPTY__ ] || id=
    [ "$actor_id" != __FM_LINEAR_EMPTY__ ] || actor_id=
    [ "$created" != __FM_LINEAR_EMPTY__ ] || created=
    [ "$to_state" != __FM_LINEAR_EMPTY__ ] || to_state=
    [ "$to_assignee_id" != __FM_LINEAR_EMPTY__ ] || to_assignee_id=
    [ "$to_assignee" != __FM_LINEAR_EMPTY__ ] || to_assignee=
    [ "$from_state" != __FM_LINEAR_EMPTY__ ] || from_state=
    [ "$from_assignee" != __FM_LINEAR_EMPTY__ ] || from_assignee=
    [ -n "$id" ] && [ -n "$created" ] || return 1
    key="history:$id"
    if seen_has "$key"; then
      if [ -n "$actor_id" ] && [ "$actor_id" = "$SELF_ID" ] && [ "$has_board" = true ]; then
        mark_outbox_board_observed "$issue" "$to_state" "$to_assignee_id"
      fi
      continue
    fi
    if [ -n "$bootstrap_cutoff" ] && [[ "$created" < "$bootstrap_cutoff" ]]; then
      seen_append "$key" "$observed" || return 1
      continue
    fi
    if [ -n "$actor_id" ] && [ "$actor_id" = "$SELF_ID" ]; then
      seen_append "$key" "$observed" || return 1
      [ "$has_board" != true ] || mark_outbox_board_observed "$issue" "$to_state" "$to_assignee_id"
      continue
    fi
    if [ "$has_board" = true ]; then
      kind=board
    elif [ "$has_description" = true ]; then
      kind=description
    elif [ "$has_labels" = true ]; then
      kind=label
    else
      seen_append "$key" "$observed" || return 1
      continue
    fi
    record="$TMP_ROOT/inbox-history-$id.json"
    jq -n --arg kind "$kind" --arg actor "$actor" --arg actor_id "$actor_id" --arg observed "$observed" \
      --arg cutoff "$bootstrap_cutoff" --arg issue "$issue" --arg id "$id" \
      --arg created "$created" --arg from_state "$from_state" --arg to_state "$to_state" \
      --arg from_assignee "$from_assignee" --arg to_assignee "$to_assignee" \
      --arg description "$has_description" --arg added "$added_b64" --arg removed "$removed_b64" '
        {kind:$kind, issue:$issue, history_id:$id, author:$actor,
         author_id:(if $actor_id == "" then null else $actor_id end),
         created_at:$created, updated_at:$created, observed_at:$observed,
         from_state:(if $from_state == "" then null else $from_state end),
         to_state:(if $to_state == "" then null else $to_state end),
         from_assignee:(if $from_assignee == "" then null else $from_assignee end),
         to_assignee:(if $to_assignee == "" then null else $to_assignee end),
         description_updated:($description == "true"),
         added_labels:($added | @base64d | fromjson),
         removed_labels:($removed | @base64d | fromjson)}
        + (if $cutoff != "" and $created >= $cutoff then {bootstrap:true} else {} end)
      ' > "$record" || return 1
    publish_inbox "$key" "$record" || return 1
    seen_append "$key" "$observed" || return 1
    NEW_EVENTS=$((NEW_EVENTS + 1))
    note_issue "$issue"
  done < "$TMP_ROOT/history-rows.tsv"
}

derive_issue_creation() {  # <observed-at> <creation-cutoff> <bootstrap-cutoff>
  local observed=$1 creation_cutoff=$2 bootstrap_cutoff=$3 row issue creator_id created key labels assignee_id text record should_wake
  jq -c 'sort_by(.createdAt, .identifier)[]' "$TMP_ROOT/issues.json" > "$TMP_ROOT/issue-rows.jsonl" || return 1
  while IFS= read -r row; do
    issue=$(printf '%s' "$row" | jq -r '.identifier // empty')
    creator_id=$(printf '%s' "$row" | jq -r '.creator.id // empty')
    created=$(printf '%s' "$row" | jq -r '.createdAt // empty')
    [ -n "$issue" ] && [ -n "$created" ] || continue
    [ -z "$creation_cutoff" ] || [[ "$created" > "$creation_cutoff" || "$created" = "$creation_cutoff" ]] || continue
    key="issue-created:$issue"
    seen_has "$key" && continue
    labels=$(printf '%s' "$row" | jq -r '[.labels.nodes[].name] | join(",")')
    assignee_id=$(printf '%s' "$row" | jq -r '.assignee.id // empty')
    text=$(printf '%s' "$row" | jq -r '[(.title // ""),(.description // "")] | join(" ") | ascii_downcase')
    should_wake=0
    case ",$labels," in *,Firstmate,*) should_wake=1 ;; esac
    [ -z "$assignee_id" ] || [ "$assignee_id" != "$SELF_ID" ] || should_wake=1
    case "$text" in *firstmate*) should_wake=1 ;; esac
    if { [ -n "$creator_id" ] && [ "$creator_id" = "$SELF_ID" ]; } || [ "$should_wake" -eq 0 ]; then
      seen_append "$key" "$observed" || return 1
      continue
    fi
    record="$TMP_ROOT/inbox-issue-$issue.json"
    printf '%s' "$row" | jq --arg observed "$observed" --arg cutoff "$bootstrap_cutoff" '
      {kind:"issue-created", issue:.identifier, author:(.creator.displayName // "unknown"),
       author_id:(.creator.id // null),
       created_at:.createdAt, updated_at:.updatedAt, observed_at:$observed,
       title:(.title // ""), labels:[.labels.nodes[].name]}
      + (if $cutoff != "" and .createdAt >= $cutoff then {bootstrap:true} else {} end)
    ' > "$record" || return 1
    publish_inbox "$key" "$record" || return 1
    seen_append "$key" "$observed" || return 1
    NEW_EVENTS=$((NEW_EVENTS + 1))
    note_issue "$issue"
  done < "$TMP_ROOT/issue-rows.jsonl"
}

audit_invariants() {
  local row issue status assignee role expected current next kept
  current="$TMP_ROOT/unknown-status-current.tsv"
  next="$TMP_ROOT/unknown-status-next.tsv"
  kept="$TMP_ROOT/unknown-status-acks-kept.tsv"
  if [ -e "$UNKNOWN_FILE" ]; then
    [ -f "$UNKNOWN_FILE" ] && [ ! -L "$UNKNOWN_FILE" ] || return 1
    cp "$UNKNOWN_FILE" "$current" || return 1
  else
    : > "$current"
  fi
  jq -c '.[]' "$TMP_ROOT/issues.json" > "$TMP_ROOT/audit-rows.jsonl" || return 1
  while IFS= read -r row; do
    issue=$(printf '%s' "$row" | jq -r '.identifier // "unknown"')
    status=$(printf '%s' "$row" | jq -r '.state.name // "unknown"')
    assignee=$(printf '%s' "$row" | jq -r '.assignee.displayName // "unassigned"')
    awk -F '\t' -v issue="$issue" '$1 != issue' "$current" > "$next" || return 1
    mv -f -- "$next" "$current" || return 1
    if role=$(fm_linear_status_role "$status"); then
      if [ "$role" = captain ]; then expected=$CAPTAIN_NAME; else expected=$SELF_NAME; fi
      [ "$assignee" = "$expected" ] \
        || printf 'linear: TURN-MARKER MISMATCH %s (%s assigned to %s, expected %s)\n' \
          "$issue" "$status" "$assignee" "$expected"
    elif ! fm_linear_status_known_without_turn_marker "$status"; then
      printf '%s\t%s\n' "$issue" "$status" >> "$current" || return 1
    fi
  done < "$TMP_ROOT/audit-rows.jsonl"
  while IFS="$(printf '\t')" read -r issue status; do
    [ -n "$issue" ] || continue
    if ! awk -F '\t' -v issue="$issue" -v status="$status" \
      '$1 == issue && $2 == status { found=1 } END { exit !found }' \
      "$UNKNOWN_ACK_FILE" 2>/dev/null; then
      printf 'linear: UNKNOWN STATUS %s (%s)\n' "$status" "$issue"
    fi
  done < "$current"
  fm_linear_atomic_file "$UNKNOWN_FILE" 600 < "$current" || return 1
  if [ -e "$UNKNOWN_ACK_FILE" ]; then
    [ -f "$UNKNOWN_ACK_FILE" ] && [ ! -L "$UNKNOWN_ACK_FILE" ] || return 1
    awk -F '\t' 'NR == FNR { current[$1 FS $2]=1; next }
      current[$1 FS $2] { print }' "$current" "$UNKNOWN_ACK_FILE" > "$kept" || return 1
    fm_linear_atomic_file "$UNKNOWN_ACK_FILE" 600 < "$kept" || return 1
  fi
}

announce_stale_pending() {
  local now oldest_epoch=0 oldest_issue=unknown count=0 file created epoch age
  now=${FM_LINEAR_NOW_EPOCH:-$(date +%s)}
  [ -d "$INBOX" ] || return 0
  for file in "$INBOX"/*.json; do
    [ -f "$file" ] || continue
    [ -e "${file%.json}.handled" ] && continue
    count=$((count + 1))
    created=$(jq -r '.created_at // empty' "$file" 2>/dev/null)
    epoch=$(fm_linear_epoch "$created" 2>/dev/null || true)
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    if [ "$oldest_epoch" -eq 0 ] || [ "$epoch" -lt "$oldest_epoch" ]; then
      oldest_epoch=$epoch
      oldest_issue=$(jq -r '.issue // "unknown"' "$file" 2>/dev/null)
    fi
  done
  [ "$count" -gt 0 ] || return 0
  [ "$oldest_epoch" -gt 0 ] || {
    printf 'linear: UNHANDLED captain inputs have unreadable timestamps\n'
    return 0
  }
  age=$((now - oldest_epoch))
  if [ "$age" -ge "${FM_LINEAR_PENDING_ALARM_SECONDS:-300}" ]; then
    printf 'linear: %s UNHANDLED captain inputs, oldest %sm (%s)\n' \
      "$count" "$((age / 60))" "$oldest_issue"
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
  local file cutoff seen_tmp heads_tmp
  cutoff=
  [ -d "$INBOX" ] || return 0
  find "$INBOX" -type f -name '*.handled' -mtime +14 -print 2>/dev/null | while IFS= read -r file; do
    rm -f -- "$file" "${file%.handled}.json" 2>/dev/null || true
  done
  if [ -f "$SEEN_FILE" ] && [ ! -L "$SEEN_FILE" ]; then
    cutoff=$(fm_linear_iso_from_epoch "$((${FM_LINEAR_NOW_EPOCH:-$(date +%s)} - 1209600))") || cutoff=
    if [ -n "$cutoff" ]; then
      seen_tmp="$TMP_ROOT/seen-pruned.tsv"
      awk -F '\t' -v cutoff="$cutoff" '$2 >= cutoff' "$SEEN_FILE" > "$seen_tmp" || return 1
      fm_linear_atomic_file "$SEEN_FILE" 600 < "$seen_tmp" || return 1
    fi
  fi
  if [ -f "$COMMENT_HEADS_FILE" ] && [ ! -L "$COMMENT_HEADS_FILE" ] && [ -n "$cutoff" ]; then
    heads_tmp="$TMP_ROOT/comment-heads-pruned.tsv"
    awk -F '\t' -v cutoff="$cutoff" '$3 >= cutoff' "$COMMENT_HEADS_FILE" > "$heads_tmp" || return 1
    fm_linear_atomic_file "$COMMENT_HEADS_FILE" 600 < "$heads_tmp" || return 1
  fi
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
  local issue=$1 status=$2 lock_status next
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
  awk -F '\t' -v issue="$issue" -v status="$status" \
    '$1 == issue && $2 == status { found=1 } END { exit !found }' "$UNKNOWN_FILE" || {
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
  printf '%s\t%s\n' "$issue" "$status" >> "$next" || return 1
  fm_linear_atomic_file "$UNKNOWN_ACK_FILE" 600 < "$next" || return 1
  printf 'linear: acknowledged unknown status %s (%s)\n' "$status" "$issue"
}

main() {
  local comments_cursor issues_cursor bootstrap_cutoff creation_cutoff comments_max issues_max observed cursor_tmp lock_status
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
  load_seen_keys || {
    record_failure "cannot read the Linear seen ledger"
    return 1
  }
  if ! command -v jq >/dev/null 2>&1; then
    record_failure "missing jq"
    return 1
  fi
  if ! fm_linear_load_key; then
    record_failure "missing LINEAR_API_KEY in $FM_HOME/.env"
    return 1
  fi

  comments_cursor=$(cursor_get comments_updated_at)
  issues_cursor=$(cursor_get issues_updated_at)
  bootstrap_cutoff=
  if [ -z "$comments_cursor" ] || [ -z "$issues_cursor" ]; then
    bootstrap_cutoff=$(fm_linear_iso_from_epoch "$((${FM_LINEAR_NOW_EPOCH:-$(date +%s)} - 7200))") || {
      record_failure "cannot calculate bootstrap horizon"
      return 1
    }
  fi

  if ! fetch_comments "$comments_cursor"; then
    record_failure "${FM_LINEAR_API_ERROR:-comments fetch failed}"
    return 1
  fi
  timing_mark comments-fetched
  if ! fetch_issues "$issues_cursor" "$bootstrap_cutoff"; then
    record_failure "${FM_LINEAR_API_ERROR:-issues fetch failed}"
    return 1
  fi
  timing_mark issues-fetched

  comments_max=$(jq -r '[.[].updatedAt] | max // empty' "$TMP_ROOT/comments.json")
  issues_max=$(jq -r '[.[].updatedAt] | max // empty' "$TMP_ROOT/issues.json")
  observed=$(printf '%s\n%s\n' "$comments_max" "$issues_max" | sed '/^$/d' | LC_ALL=C sort | tail -n 1)
  creation_cutoff=${issues_cursor:-$bootstrap_cutoff}

  if ! derive_comments "$observed" "$bootstrap_cutoff"; then
    record_failure "cannot persist Linear event ledger"
    return 1
  fi
  timing_mark comments-derived
  if ! derive_history "$observed" "$bootstrap_cutoff"; then
    record_failure "cannot persist Linear event ledger"
    return 1
  fi
  timing_mark history-derived
  if ! derive_issue_creation "$observed" "$creation_cutoff" "$bootstrap_cutoff"; then
    record_failure "cannot persist Linear event ledger"
    return 1
  fi
  timing_mark issues-derived

  if [ -n "$comments_max" ] || [ -n "$issues_max" ]; then
    cursor_tmp="$TMP_ROOT/cursor"
    {
      printf 'comments_updated_at=%s\n' "${comments_max:-$comments_cursor}"
      printf 'issues_updated_at=%s\n' "${issues_max:-$issues_cursor}"
    } > "$cursor_tmp"
    if [ -n "$comments_cursor" ] && [ -n "$comments_max" ] && [ "$comments_max" "<" "$comments_cursor" ]; then
      record_failure "CURSOR ANOMALY comments would move backwards"
      return 1
    fi
    if [ -n "$issues_cursor" ] && [ -n "$issues_max" ] && [ "$issues_max" "<" "$issues_cursor" ]; then
      record_failure "CURSOR ANOMALY issues would move backwards"
      return 1
    fi
    fm_linear_atomic_file "$CURSOR_FILE" 600 < "$cursor_tmp" || {
      record_failure "cannot publish Linear cursor"
      return 1
    }
  fi

  record_success "$observed" || {
    printf 'linear: POLL STATE FAILURE: cannot persist success health\n'
    return 1
  }
  audit_invariants || printf 'linear: POLL STATE FAILURE: invariant audit failed\n'
  announce_stale_pending
  announce_outbox
  prune_retained_state
  if [ "$NEW_EVENTS" -gt 0 ]; then
    printf 'linear: %s captain input(s) pending:%s\n' "$NEW_EVENTS" "$NEW_ISSUES"
  fi
}

case "${1:-}" in
  '') main ;;
  acknowledge-unknown-status)
    [ "$#" -eq 3 ] || { printf 'usage: fm-linear-poll.sh acknowledge-unknown-status <BIG-n> <status>\n' >&2; exit 2; }
    acknowledge_unknown_status "$2" "$3"
    ;;
  *) printf 'usage: fm-linear-poll.sh [acknowledge-unknown-status <BIG-n> <status>]\n' >&2; exit 2 ;;
esac
