#!/usr/bin/env bash
# Shared primitives for the Linear event ledger and outbound write journal.
# Usage: source bin/fm-linear-lib.sh from fm-linear-poll.sh, fm-linear-act.sh, or fm-bootstrap.sh.
#
# This file is sourced by fm-linear-poll.sh, fm-linear-act.sh, and bootstrap.
# It owns Linear credential resolution, private state publication, fixture-backed
# GraphQL transport, identity-shim bytes, timestamps, hashes, UUID generation,
# and the status-to-assignee truth table.

fm_linear_env_get() {  # <key> <file>
  local key=$1 file=$2 line value
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n 1) || return 0
  [ -n "$line" ] || return 0
  value=${line#*=}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s' "$value"
}

fm_linear_load_key() {
  FM_LINEAR_KEY=${LINEAR_API_KEY:-}
  [ -n "$FM_LINEAR_KEY" ] || FM_LINEAR_KEY=$(fm_linear_env_get LINEAR_API_KEY "$FM_HOME/.env")
  [ -n "$FM_LINEAR_KEY" ]
}

fm_linear_activation_approved() {  # <activation-file>
  local file=$1 value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r value <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _ <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$value" = approved ]
}

fm_linear_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_linear_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    return 1
  fi
}

fm_linear_epoch() {
  local timestamp=$1
  printf '%s' "$timestamp" | jq -Rr '
    sub("\\.[0-9]+Z$"; "Z")
    | try fromdateiso8601 catch empty
  '
}

fm_linear_iso_from_epoch() {
  jq -nr --argjson epoch "$1" '$epoch | todateiso8601'
}

fm_linear_overlap_timestamp() {
  local epoch
  epoch=$(fm_linear_epoch "$1") || return 1
  [ -n "$epoch" ] || return 1
  fm_linear_iso_from_epoch "$((epoch - ${FM_LINEAR_OVERLAP_SECONDS:-300}))"
}

fm_linear_private_dir() {  # <path>
  local path=$1 mode
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
  else
    (umask 077; mkdir -p "$path") || return 1
  fi
  chmod 0700 "$path" 2>/dev/null || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$path" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$path" 2>/dev/null) || return 1
  fi
  [ "$mode" = 700 ]
}

fm_linear_lock_acquire() {  # <lock-directory>
  local lock=$1 owner
  if mkdir "$lock" 2>/dev/null; then
    :
  else
    [ -d "$lock" ] && [ ! -L "$lock" ] || return 2
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    case "$owner" in ''|*[!0-9]*) return 2 ;; esac
    kill -0 "$owner" 2>/dev/null && return 1
    rm -f -- "$lock/pid" 2>/dev/null || return 2
    rmdir "$lock" 2>/dev/null || return 2
    mkdir "$lock" 2>/dev/null || return 2
  fi
  printf '%s\n' "$$" > "$lock/pid" || {
    rmdir "$lock" 2>/dev/null || true
    return 2
  }
}

fm_linear_lock_release() {  # <lock-directory>
  local lock=$1
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$$" ] || return 0
  rm -f -- "$lock/pid" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null || return 1
}

fm_linear_atomic_file() {  # <destination> <mode>, content on stdin
  local destination=$1 mode=$2 parent tmp current_mode
  parent=${destination%/*}
  fm_linear_private_dir "$parent" || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-linear.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ "$(uname)" = Darwin ]; then
    current_mode=$(stat -f %Lp "$tmp" 2>/dev/null) || current_mode=
  else
    current_mode=$(stat -c %a "$tmp" 2>/dev/null) || current_mode=
  fi
  if [ "$current_mode" != "$mode" ] || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_linear_fixture_next() {
  local index file
  FM_LINEAR_FIXTURE_INDEX=$((FM_LINEAR_FIXTURE_INDEX + 1))
  index=$FM_LINEAR_FIXTURE_INDEX
  file=$(find "$FM_LINEAR_FIXTURE_DIR" -maxdepth 1 -type f ! -name '.*' -print \
    | LC_ALL=C sort | sed -n "${index}p")
  [ -n "$file" ] || return 1
  FM_LINEAR_FIXTURE_NEXT=$file
}

fm_linear_api_call() {  # <operation> <payload-file> <response-file>
  local operation=$1 payload=$2 response=$3 fixture base header code status fixture_comment fixture_expanded
  local comment_store comment_id
  FM_LINEAR_API_ERROR=
  if [ -n "${FM_LINEAR_FIXTURE_DIR:-}" ]; then
    fm_linear_fixture_next || {
      FM_LINEAR_API_ERROR="fixture response missing for $operation"
      return 1
    }
    fixture=$FM_LINEAR_FIXTURE_NEXT
    base=${fixture##*/}
    if [ -n "${FM_LINEAR_FIXTURE_LOG:-}" ]; then
      printf '%s\t%s\n' "$operation" "$(jq -c . "$payload" 2>/dev/null || printf malformed)" \
        >> "$FM_LINEAR_FIXTURE_LOG"
    fi
    case "$base" in
      *fail-*)
        code=$(printf '%s' "$base" | sed -n 's/.*fail-\([0-9][0-9]*\).*/\1/p')
        FM_LINEAR_API_ERROR="HTTP ${code:-500} during $operation"
        return 1
        ;;
      *malformed*)
        cp "$fixture" "$response" 2>/dev/null || printf '{malformed' > "$response"
        FM_LINEAR_API_ERROR="malformed JSON during $operation"
        return 1
        ;;
    esac
    cp "$fixture" "$response" || {
      FM_LINEAR_API_ERROR="cannot read fixture for $operation"
      return 1
    }
    if jq -e . "$response" >/dev/null 2>&1; then
      fixture_comment=$(jq -r '.variables.comment // .variables.id // empty' "$payload" 2>/dev/null) || fixture_comment=
      if [ -n "$fixture_comment" ]; then
        fixture_expanded="${response}.expanded"
        jq --arg comment "$fixture_comment" '
          walk(if type == "string" and . == "__COMMENT_ID__" then $comment else . end)
        ' "$response" > "$fixture_expanded" || {
          FM_LINEAR_API_ERROR="cannot expand fixture for $operation"
          return 1
        }
        mv -f -- "$fixture_expanded" "$response" || return 1
      fi
    fi
  else
    header=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear-header.XXXXXX") || {
      FM_LINEAR_API_ERROR="cannot create authorization header"
      return 1
    }
    printf 'Authorization: %s\n' "$FM_LINEAR_KEY" > "$header" || {
      rm -f -- "$header"
      FM_LINEAR_API_ERROR="cannot write authorization header"
      return 1
    }
    code=$(curl -sS -m "${FM_LINEAR_HTTP_TIMEOUT:-20}" -o "$response" -w '%{http_code}' \
      -X POST https://api.linear.app/graphql \
      -H "@$header" -H 'Content-Type: application/json' \
      --data-binary "@$payload" 2>/dev/null)
    status=$?
    rm -f -- "$header"
    if [ "$status" -ne 0 ]; then
      FM_LINEAR_API_ERROR="transport failure during $operation"
      return 1
    fi
    case "$code" in
      2??) ;;
      *) FM_LINEAR_API_ERROR="HTTP $code during $operation"; return 1 ;;
    esac
  fi
  if ! jq -e 'type == "object"' "$response" >/dev/null 2>&1; then
    FM_LINEAR_API_ERROR="malformed JSON during $operation"
    return 1
  fi
  comment_store=${FM_LINEAR_FIXTURE_COMMENT_STORE:-}
  if [ -n "$comment_store" ] && [ "$operation" = commentCreate ]; then
    comment_id=$(jq -r '.variables.id // empty' "$payload" 2>/dev/null) || comment_id=
    [ -n "$comment_id" ] || {
      FM_LINEAR_API_ERROR="fixture comment ID missing"
      return 1
    }
    if awk -v id="$comment_id" '$0 == id { found=1 } END { exit !found }' \
      "$comment_store" 2>/dev/null; then
      FM_LINEAR_API_ERROR="comment already exists"
      return 1
    fi
    if jq -e '.data.commentCreate.success == true' "$response" >/dev/null 2>&1; then
      printf '%s\n' "$comment_id" >> "$comment_store" || {
        FM_LINEAR_API_ERROR="cannot persist fixture comment acceptance"
        return 1
      }
    fi
  fi
  if jq -e '.errors != null and (.errors | length > 0)' "$response" >/dev/null 2>&1; then
    # shellcheck disable=SC2034 # Returned to the sourcing caller as the transport diagnostic.
    FM_LINEAR_API_ERROR=$(jq -r '"GraphQL error during '"$operation"': " + ([.errors[].message] | join("; "))' "$response")
    return 1
  fi
}

fm_linear_status_role() {  # <status>
  case "$1" in
    'Approve Deliverable'|'Approve Plan'|'Needs Decision') printf 'captain\n' ;;
    'Building'|'Validating Code'|'Plan In Progress'|'Needs Firstmate Decision') printf 'firstmate\n' ;;
    *) return 1 ;;
  esac
}

fm_linear_status_known_without_turn_marker() {
  case "$1" in
    Backlog|ToDo|Done|Canceled|Duplicate) return 0 ;;
    *) return 1 ;;
  esac
}

fm_linear_poll_shim_content() {  # <home> <root>
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-bootstrap.sh - Linear event-ledger poll shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-linear-poll.sh")"
}

fm_linear_poll_shim_valid() {  # <file> <home> <root>
  local file=$1 home=$2 root=$3 expected
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  expected=$(fm_linear_poll_shim_content "$home" "$root")
  cmp -s "$file" <(printf '%s\n' "$expected")
}
