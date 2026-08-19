#!/usr/bin/env bash
# fm-review-dispatch.sh - pick the one third-party review for a PR, record the
# dispatch in the captain-private ledger, and report credit state.
#
# This script is the single owner of dispatch mechanics: the exact commands,
# flags, ledger format, and refusal conditions below. The reviewing doctrine
# lives in josh-padnick/code-review, and the merge-time evidence contract stays
# with the BIG-164 gate; neither is restated here.
#
# Usage:
#   fm-review-dispatch.sh choose <pr-url> [--after-refusal] [--service <name>]
#                                         [--devin-quota-confirmed]
#   fm-review-dispatch.sh record <pr-url> <service> <event> [--note <text>]
#                                 <event> is requested, refused, reviewed,
#                                 or exhausted
#   fm-review-dispatch.sh reconcile <service> <remaining> [--note <text>]
#   fm-review-dispatch.sh status
#   fm-review-dispatch.sh check <pr-url> [--ledger-only]
#   fm-review-dispatch.sh -h | --help
#
# Services are coderabbit, greptile, devin, and in-house.
#
# Exit status:
#   0  the request succeeded
#   1  a usage, input, or environment error
#   2  a refusal: the rules below say no, or a check found an inconsistency
#
# `choose` prints the one service to dispatch and the exact trigger comment.
# CodeRabbit is the default because its allowance is a rolling hourly window
# that costs nothing; the depletable pools are reached only after a refusal is
# recorded, because silence is not refusal and a slow first service reviewing
# after a second was dispatched would double-spend. Wait beats switch: a
# CodeRabbit refusal names its own retry time, and re-triggering it is the
# default response - `choose <pr-url> --service coderabbit` names that retry and
# prints the `record` step that puts the re-trigger back on the ledger.
# --after-refusal is the caller's statement that waiting would genuinely block
# the captain.
#
# Exactly one owner per PR: the first recorded `requested` row makes that
# service the PR's review owner. Fix rounds re-use the same owner, so `choose`
# on an owned PR prints that owner - with the same cost and `record` step as any
# other dispatch - and refuses to name a different one. Ownership moves only
# after a `refused` row for the current owner, or an `exhausted` row when that
# service's pool has no credits left to spend on this PR.
#
# Greptile costs one of GREPTILE_MONTHLY_CREDITS per review and its flex cap is
# $0, so an over-budget review is skipped and consumes nothing. Per PR the
# ledger charges each dispatch not cancelled by a later refusal, each review a
# dispatch cannot answer for, and each review that arrived before the PR was
# ever dispatched, so a refunded dispatch costs nothing while a review it never
# produced is still spend. Auto-picks stop at GREPTILE_RESERVE_FLOOR remaining; below the floor Greptile
# is captain-explicit only (--service greptile), and at zero remaining it is
# refused outright because the cap would make the dispatch a no-op. Every
# Greptile dispatch carries those rules, including a fix round on a PR Greptile
# already owns. A PR Greptile owns at zero remaining is released with
# `record <pr-url> greptile exhausted`, which is what actually happened: no
# dispatch was made.
#
# A fix-round re-review is counted as one more Greptile credit, because Greptile
# bills a second credit for a re-review on the same PR.
#
# Devin is reserve. `choose` reaches it only on explicit captain choice
# (--service devin) or, in the after-refusal chain, when the captain has read
# the dashboard and passes --devin-quota-confirmed. Its quota is not ledger
# countable, so no automatic path infers it.
#
# When every pool is unavailable, `choose` names the in-house adversarial
# review rather than stalling. Once every third-party service is recorded as
# refused or exhausted for a PR, that choice needs no --after-refusal: the flag
# guards moves to a paid pool, and the in-house review costs nothing.
#
# The ledger is $FM_HOME/data/review-dispatch/ledger.tsv, captain-private and
# gitignored with the rest of data/. One tab-separated row per event:
#
#   <iso8601-utc>	<pr-url or ->	<service>	<event>	<note>
#
# Events are requested, refused, reviewed, exhausted, and reconcile. A
# `refused` row says the service declined; an `exhausted` row says its pool had
# no credits, so nothing was dispatched. Both release the PR and take that
# service out of its selection, and neither refunds a credit already spent. No
# balance API
# exists, so this file is the source of truth for remaining Greptile credits;
# the captain's dashboard is the monthly reconciliation source, and
# `reconcile greptile <remaining>` writes the relayed number as a `remaining=`
# note that later credit math counts forward from. Drift is corrected in the
# ledger rather than guessed at.
#
# `check` compares the recorded owner against the review evidence on the PR
# itself. Evidence lives in PR comments rather than GitHub review objects, so
# the comparison reads comment authors through `gh --json` (the structured
# surface; gh-axi is the agent-facing one). A second service's evidence on an
# owned PR is reported as a leak, unless the ledger records that service as
# having refused this PR: its refusal is itself delivered as a comment.
#
# Environment:
#   FM_HOME                    home whose data/ holds the ledger
#   FM_DATA_OVERRIDE           data directory override
#   FM_REVIEW_DISPATCH_NOW     ISO-8601 UTC timestamp used instead of the clock
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

# Greptile's included allowance and the reserve the auto-picks never spend.
# Decision 3 of the BIG-143 plan: one constant, not a pacing schedule.
GREPTILE_MONTHLY_CREDITS=50
GREPTILE_RESERVE_FLOOR=10

LEDGER_DIR="$DATA/review-dispatch"
LEDGER="$LEDGER_DIR/ledger.tsv"
LOCK="$LEDGER.lock"
LOCK_HELD=0

NOW=${FM_REVIEW_DISPATCH_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {  # usage or environment error
  printf 'fm-review-dispatch: %s\n' "$*" >&2
  exit 1
}

refuse() {  # the rules say no
  printf 'fm-review-dispatch: %s\n' "$*" >&2
  exit 2
}

cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    rmdir "$LOCK" 2>/dev/null || true
    LOCK_HELD=0
  fi
}
trap cleanup EXIT

# Serialize the read-modify-write in record/reconcile so two concurrent writers
# cannot both decide a PR is unowned. A holder that died mid-write is broken
# after FM_REVIEW_DISPATCH_LOCK_STALE_SECS.
lock_acquire() {
  local tries=0 now mtime age old_umask
  old_umask=$(umask)
  umask 077
  mkdir -p "$LEDGER_DIR"
  umask "$old_umask"
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      now=$(date +%s)
      mtime=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now")
      age=$((now - mtime))
      if [ "$age" -ge "${FM_REVIEW_DISPATCH_LOCK_STALE_SECS:-5}" ]; then
        rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null && break
      fi
      fail "ledger lock timeout"
    fi
    sleep 0.05
  done
  LOCK_HELD=1
}

# --- validation -------------------------------------------------------------

validate_service() {  # <service>
  case "${1:-}" in
    coderabbit|greptile|devin|in-house) : ;;
    *) fail "unknown service: ${1:-} (coderabbit, greptile, devin, in-house)" ;;
  esac
}

validate_event() {  # <event>
  case "${1:-}" in
    requested|refused|reviewed|exhausted) : ;;
    *) fail "unknown event: ${1:-} (requested, refused, reviewed, exhausted)" ;;
  esac
}

validate_note() {  # <note>
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*) fail "--note must be one line and must not contain tabs" ;;
  esac
}

validate_pr_url() {  # <url>; echoes the canonical URL
  fm_pr_url_parse "${1:-}" || fail "not a pull request URL: ${1:-}"
  printf '%s\n' "$FM_PR_URL"
}

# --- ledger reads -----------------------------------------------------------

ledger_rows() {
  [ -f "$LEDGER" ] || return 0
  grep -v '^#' "$LEDGER" 2>/dev/null | grep -v '^[[:space:]]*$' || true
}

# Space-delimited set helpers. list_add takes the variable NAME so a caller can
# accumulate into its own local.
list_add() {  # <var-name> <value>
  local name=$1 value=$2 current
  eval "current=\${$name}"
  case " $current " in
    *" $value "*) return 0 ;;
  esac
  eval "$name=\"\${$name} \$value\""
  eval "$name=\${$name# }"
}

list_has() {  # <list> <value>
  case " $1 " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Rows for one PR, in append order.
pr_rows() {  # <pr-url>
  local url=$1
  ledger_rows | awk -F '\t' -v url="$url" '$2 == url'
}

# The PR's state machine, folded in append order. Sets:
#   PR_OWNER       the live review owner, empty when ownership is open
#   PR_REFUSED     space-delimited services that refused this PR
#   PR_EXHAUSTED   space-delimited services whose pool was dry for this PR
#   PR_REVIEWED    space-delimited services whose review was recorded
#   PR_UNAVAILABLE refused and exhausted together: out of this PR's selection
fold_pr_state() {  # <pr-url>
  local ts service event
  PR_OWNER=
  PR_REFUSED=
  PR_EXHAUSTED=
  PR_REVIEWED=
  PR_UNAVAILABLE=
  while IFS=$'\t' read -r ts _ service event _; do
    [ -n "${ts:-}" ] || continue
    case "$event" in
      requested) PR_OWNER=$service ;;
      refused)
        list_add PR_REFUSED "$service"
        if [ "$PR_OWNER" = "$service" ]; then
          PR_OWNER=
        fi
        ;;
      exhausted)
        list_add PR_EXHAUSTED "$service"
        if [ "$PR_OWNER" = "$service" ]; then
          PR_OWNER=
        fi
        ;;
      reviewed) list_add PR_REVIEWED "$service" ;;
    esac
  done < <(pr_rows "$1")
  PR_UNAVAILABLE=$PR_REFUSED
  for service in $PR_EXHAUSTED; do
    list_add PR_UNAVAILABLE "$service"
  done
}


# The billing month the ledger counts against, as YYYY-MM.
billing_month() {
  printf '%s\n' "${NOW:0:7}"
}

# Every Greptile credit the ledger says was spent, one line per credit, as
#
#   <ledger-row-number>\t<iso8601-utc>
#
# of the row that credit is charged to. One fold over the whole ledger, never
# scoped to a billing month or a reconcile baseline: a review answers for a
# dispatch recorded in an earlier month just as well as for one recorded today,
# and scoping the fold is what once charged that review twice.
#
# Per PR, one order-aware fold replaces every rule this counting used to carry.
# Walking the ledger in append order:
#
#   - a `requested` row opens a standing dispatch;
#   - a `reviewed` row answers the most recent unanswered standing dispatch,
#     and charges a credit of its own when there is none to answer;
#   - a `refused` row cancels the most recent unanswered standing dispatch, so
#     the refund lands on the dispatch it followed rather than on some other
#     window's; a dispatch a review already answered is not cancellable.
#
#   charged = reviews that charged on their own
#             + dispatches still standing at the end
#
# A review is never absorbed by a dispatch that came after it - the order the
# ledger records is the order the credits were spent. Each charge is attributed
# to a row, a dispatch to its `requested` row and a self-charging review to its
# `reviewed` row, so the caller can decide which billing window owns it.
#
#   case                     rows                      self  standing  charged
#   plain dispatch           req                       0     1         1
#   refunded dispatch        req, ref                  0     0         0
#   retry path               req, ref, req             0     1         1
#   true leak                rev                       1     0         1
#   cross-window review      req (Jul), rev (Aug)      0     1         1
#   cross-window refusal     req (Jul), req, ref       0     1         1
#   cross-window retry       req (Jul), ref, req       0     1         1
#   same-PR re-review        req, rev, rev             1     1         2
#   reviewed then refused    req, rev, ref             0     1         1
#   refused then reviewed    req, ref, rev             1     0         1
#   refunded, re-reviewed    req, ref, req, rev, rev   1     1         2
#   leaked then dispatched   rev, req                  1     1         2
#   reviewed, refused, retry req, rev, ref, req        0     2         2
#
# "A recorded review locks its credit in against a later refusal" is no longer
# its own rule, and neither is the narrower "a review before this PR's first
# dispatch is a credit of its own": both fall out of the order-aware fold, in
# which a delivered review has already answered its dispatch by the time any
# later row is read.
greptile_charges() {
  ledger_rows | awk -F '\t' '
    $3 != "greptile" { next }
    { pr = $2; seen[pr] = 1 }
    $4 == "requested" {
      opened[pr]++
      row[pr, opened[pr]] = NR
      when[pr, opened[pr]] = $1
      standing[pr, opened[pr]] = 1
      answered[pr, opened[pr]] = 0
      next
    }
    $4 == "refused" {
      for (i = opened[pr]; i >= 1; i--)
        if (standing[pr, i] && !answered[pr, i]) { standing[pr, i] = 0; break }
      next
    }
    $4 == "reviewed" {
      for (i = opened[pr]; i >= 1; i--)
        if (standing[pr, i] && !answered[pr, i]) { answered[pr, i] = 1; break }
      if (i < 1) {
        self[pr]++
        self_row[pr, self[pr]] = NR
        self_when[pr, self[pr]] = $1
      }
      next
    }
    END {
      for (pr in seen) {
        for (i = 1; i <= self[pr]; i++)
          printf "%s\t%s\n", self_row[pr, i], self_when[pr, i]
        for (i = 1; i <= opened[pr]; i++)
          if (standing[pr, i])
            printf "%s\t%s\n", row[pr, i], when[pr, i]
      }
    }
  '
}

# Greptile credits remaining this billing month. Counts forward from the latest
# captain-relayed reconcile row in the month when one exists, and from the full
# monthly allowance otherwise: every charge attributed to a row after that
# baseline and inside the month is spend the baseline does not already hold.
# Position, not timestamp, orders the ledger, so two rows written in the same
# second still count once each.
greptile_remaining() {
  local month baseline baseline_row=0 spent=0 index=0 ts service event note relayed
  month=$(billing_month)
  baseline=$GREPTILE_MONTHLY_CREDITS
  while IFS=$'\t' read -r ts _ service event note; do
    index=$((index + 1))
    [ "$service" = greptile ] && [ "$event" = reconcile ] || continue
    case "$ts" in "$month"-*) : ;; *) continue ;; esac
    case "$note" in
      remaining=*) relayed=${note#remaining=} ; relayed=${relayed%% *} ;;
      *) continue ;;
    esac
    case "$relayed" in ''|*[!0-9]*) continue ;; esac
    baseline=$relayed
    baseline_row=$index
  done < <(ledger_rows)

  while IFS=$'\t' read -r index ts; do
    [ "$index" -gt "$baseline_row" ] || continue
    case "$ts" in "$month"-*) spent=$((spent + 1)) ;; esac
  done < <(greptile_charges)
  printf '%s\n' "$((baseline - spent))"
}

# The last captain-relayed number for a service, or the empty string.
last_reconcile() {  # <service>
  local ts service event note out=''
  while IFS=$'\t' read -r ts _ service event note; do
    [ "$service" = "$1" ] && [ "$event" = reconcile ] || continue
    out="$ts $note"
  done < <(ledger_rows)
  printf '%s\n' "$out"
}

# --- ledger writes ----------------------------------------------------------

append_row() {  # <pr-url or -> <service> <event> <note>
  local old_umask
  old_umask=$(umask)
  umask 077
  mkdir -p "$LEDGER_DIR"
  if [ ! -f "$LEDGER" ]; then
    printf '#date\tpr\tservice\tevent\tnote\n' > "$LEDGER"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$NOW" "$1" "$2" "$3" "$4" >> "$LEDGER"
  umask "$old_umask"
}

# --- service facts ----------------------------------------------------------

service_trigger() {  # <service>
  case "$1" in
    coderabbit) printf '@coderabbitai review\n' ;;
    greptile) printf '@greptileai\n' ;;
    devin) printf '/devin review\n' ;;
    in-house) printf '(no bot comment - dispatch the in-house adversarial review)\n' ;;
  esac
}

# GitHub logins that carry each service's review evidence.
service_logins() {  # <service>
  case "$1" in
    coderabbit) printf 'coderabbitai\n' ;;
    greptile) printf 'greptile-apps\ngreptileai\n' ;;
    devin) printf 'devin-ai-integration\n' ;;
  esac
}

# Every Greptile dispatch passes here first: refused outright at zero because
# the $0 flex cap would make the review a no-op, warned at or below the reserve
# floor. Auto-picks never reach it - they stop above the floor on their own.
# Only a PR Greptile actually owns is told to record the `exhausted` release;
# the ledger is never asked to record a release that did not happen.
greptile_guard() {  # <pr-url> owner|unowned
  local url=$1 held=$2 remaining
  remaining=$(greptile_remaining)
  if [ "$remaining" -le 0 ]; then
    if [ "$held" = owner ]; then
      refuse "the ledger shows 0 Greptile credits this month and the flex cap is \$0, so the review would be skipped; release the PR with: bin/fm-review-dispatch.sh record $url greptile exhausted - or reconcile against the dashboard if it disagrees"
    fi
    refuse "the ledger shows 0 Greptile credits this month and the flex cap is \$0, so the review would be skipped; nothing was dispatched, so $url has nothing to release; reconcile against the dashboard if it disagrees"
  fi
  if [ "$remaining" -le "$GREPTILE_RESERVE_FLOOR" ]; then
    printf 'warning: %s credits remain, at or below the reserve floor of %s; below the floor greptile is captain-explicit only\n' \
      "$remaining" "$GREPTILE_RESERVE_FLOOR" >&2
  fi
}

print_choice() {  # <pr-url> <service> <reason>
  local url=$1 service=$2 reason=$3
  printf 'service: %s\n' "$service"
  printf 'trigger: %s\n' "$(service_trigger "$service")"
  printf 'reason: %s\n' "$reason"
  case "$service" in
    coderabbit)
      printf 'pre-check: @coderabbitai rate limit (zero cost, reports the rolling window)\n'
      ;;
    greptile)
      printf 'cost: 1 credit, %s remaining before this review\n' "$(greptile_remaining)"
      ;;
    in-house)
      printf 'doctrine: https://github.com/josh-padnick/code-review (read AGENTS.md before reviewing)\n'
      printf 'attestation: required in the BIG-164 format before the gate accepts this review\n'
      ;;
  esac
  printf 'record: bin/fm-review-dispatch.sh record %s %s requested\n' "$url" "$service"
}

# --- commands ---------------------------------------------------------------

cmd_choose() {
  local url after_refusal=0 explicit='' devin_confirmed=0 remaining reason
  [ "$#" -ge 1 ] || fail "choose needs a PR URL"
  url=$(validate_pr_url "$1")
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --after-refusal) after_refusal=1 ;;
      --devin-quota-confirmed) devin_confirmed=1 ;;
      --service) shift; [ "$#" -gt 0 ] || fail "--service needs a value"; explicit=$1 ;;
      --service=*) explicit=${1#--service=} ;;
      *) fail "unknown choose option: $1" ;;
    esac
    shift
  done
  [ -z "$explicit" ] || validate_service "$explicit"

  fold_pr_state "$url"

  if [ -n "$PR_OWNER" ]; then
    if [ -n "$explicit" ] && [ "$explicit" != "$PR_OWNER" ]; then
      refuse "$url is already owned by $PR_OWNER; record its refusal before dispatching $explicit"
    fi
    if [ "$after_refusal" = 1 ]; then
      refuse "$url is still owned by $PR_OWNER; record the refusal first: bin/fm-review-dispatch.sh record $url $PR_OWNER refused"
    fi
    if [ "$PR_OWNER" = greptile ]; then
      greptile_guard "$url" owner
    fi
    print_choice "$url" "$PR_OWNER" "existing owner of this PR; fix rounds re-use it"
    return 0
  fi

  if [ -n "$explicit" ]; then
    # Wait beats switch: re-triggering the service that refused is the default
    # response, so an explicit pick of a service this PR already recorded as
    # refused is the retry path, not a second owner. It re-establishes ownership
    # through the same `record ... requested` step every other choice prints.
    reason="explicit captain choice"
    if list_has "$PR_REFUSED" "$explicit"; then
      reason="retry after the recorded $explicit refusal; wait beats switch"
    elif list_has "$PR_EXHAUSTED" "$explicit"; then
      reason="retry after the recorded $explicit exhaustion"
    fi
    if [ "$explicit" = greptile ]; then
      greptile_guard "$url" unowned
    fi
    print_choice "$url" "$explicit" "$reason"
    return 0
  fi

  if ! list_has "$PR_UNAVAILABLE" coderabbit; then
    print_choice "$url" coderabbit "default service; its hourly allowance costs no credits"
    return 0
  fi

  # A dry fleet gets our own review rather than a stall, and --after-refusal is
  # not asked for it: that flag guards a move to a paid pool, and this one is
  # free. Devin is unreachable without --devin-quota-confirmed, so an
  # unconfirmed reserve is as unavailable as a recorded one.
  if list_has "$PR_UNAVAILABLE" greptile &&
    { [ "$devin_confirmed" = 0 ] || list_has "$PR_UNAVAILABLE" devin; }; then
    if list_has "$PR_UNAVAILABLE" devin; then
      reason="every third-party service is recorded as refused or exhausted for this PR"
    else
      reason="coderabbit and greptile are recorded as refused or exhausted for this PR, and devin is unreachable without --devin-quota-confirmed"
    fi
    print_choice "$url" in-house "$reason"
    return 0
  fi

  if [ "$after_refusal" = 0 ]; then
    refuse "coderabbit is recorded as unavailable for $url; wait beats switch. Re-trigger it after its retry window with: bin/fm-review-dispatch.sh choose $url --service coderabbit - or pass --after-refusal when waiting would genuinely block the captain"
  fi

  if ! list_has "$PR_UNAVAILABLE" greptile; then
    remaining=$(greptile_remaining)
    if [ "$remaining" -gt "$GREPTILE_RESERVE_FLOOR" ]; then
      print_choice "$url" greptile "coderabbit refused and $remaining credits remain, above the reserve floor of $GREPTILE_RESERVE_FLOOR"
      return 0
    fi
    printf 'note: greptile skipped, %s credits at or below the reserve floor of %s (captain-explicit only)\n' \
      "$remaining" "$GREPTILE_RESERVE_FLOOR" >&2
  fi

  if [ "$devin_confirmed" = 1 ] && ! list_has "$PR_UNAVAILABLE" devin; then
    print_choice "$url" devin "coderabbit refused, greptile unavailable, and the captain confirmed Devin quota"
    return 0
  fi

  print_choice "$url" in-house "every third-party pool is unavailable for this PR"
}

cmd_record() {
  local url service event note='' remaining
  [ "$#" -ge 3 ] || fail "record needs a PR URL, a service, and an event"
  url=$(validate_pr_url "$1")
  service=$2
  event=$3
  shift 3
  validate_service "$service"
  validate_event "$event"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) shift; [ "$#" -gt 0 ] || fail "--note needs a value"; note=$1 ;;
      --note=*) note=${1#--note=} ;;
      *) fail "unknown record option: $1" ;;
    esac
    shift
  done
  validate_note "$note"

  lock_acquire
  fold_pr_state "$url"

  case "$event" in
    requested)
      if [ -n "$PR_OWNER" ] && [ "$PR_OWNER" != "$service" ]; then
        refuse "$url is already owned by $PR_OWNER; record its refusal before recording a $service dispatch"
      fi
      if [ "$service" = greptile ]; then
        remaining=$(greptile_remaining)
        if [ "$remaining" -le "$GREPTILE_RESERVE_FLOOR" ]; then
          printf 'warning: recording a greptile dispatch with %s credits remaining, at or below the reserve floor of %s\n' \
            "$remaining" "$GREPTILE_RESERVE_FLOOR" >&2
        fi
      fi
      ;;
    reviewed)
      if [ -n "$PR_OWNER" ] && [ "$PR_OWNER" != "$service" ]; then
        printf 'warning: %s reviewed %s, which is owned by %s; recording the leak\n' \
          "$service" "$url" "$PR_OWNER" >&2
      fi
      ;;
  esac

  append_row "$url" "$service" "$event" "$note"
  printf 'recorded: %s %s %s\n' "$url" "$service" "$event"
}

cmd_reconcile() {
  local service remaining note=''
  [ "$#" -ge 2 ] || fail "reconcile needs a service and the dashboard number"
  service=$1
  remaining=$2
  shift 2
  validate_service "$service"
  case "$service" in
    coderabbit|in-house) fail "reconcile applies to the depletable pools (greptile, devin)" ;;
  esac
  case "$remaining" in
    ''|*[!0-9]*) fail "remaining must be a whole number: $remaining" ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) shift; [ "$#" -gt 0 ] || fail "--note needs a value"; note=$1 ;;
      --note=*) note=${1#--note=} ;;
      *) fail "unknown reconcile option: $1" ;;
    esac
    shift
  done
  validate_note "$note"

  lock_acquire
  append_row - "$service" reconcile "remaining=$remaining${note:+ $note}"
  printf 'reconciled: %s remaining=%s\n' "$service" "$remaining"
}

cmd_status() {
  local month remaining relayed url owner last_refusal open
  month=$(billing_month)
  remaining=$(greptile_remaining)
  printf 'billing month: %s\n' "$month"
  printf 'greptile: %s of %s credits remaining, reserve floor %s' \
    "$remaining" "$GREPTILE_MONTHLY_CREDITS" "$GREPTILE_RESERVE_FLOOR"
  if [ "$remaining" -gt "$GREPTILE_RESERVE_FLOOR" ]; then
    printf ' - auto-picks allowed\n'
  else
    printf ' - captain-explicit only\n'
  fi
  relayed=$(last_reconcile greptile)
  printf 'greptile reconcile: %s\n' "${relayed:-none relayed yet}"
  relayed=$(last_reconcile devin)
  printf 'devin: reserve, captain-explicit; last relayed quota: %s\n' "${relayed:-none}"

  last_refusal=$(ledger_rows | awk -F '\t' '$3 == "coderabbit" && $4 == "refused"' | tail -1)
  if [ -n "$last_refusal" ]; then
    printf 'coderabbit: last refusal %s\n' \
      "$(printf '%s' "$last_refusal" | awk -F '\t' '{print $1 " on " $2 (($5 == "") ? "" : " (" $5 ")")}')"
  else
    printf 'coderabbit: no refusal recorded\n'
  fi

  printf 'open owners:\n'
  open=0
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    fold_pr_state "$url"
    [ -n "$PR_OWNER" ] || continue
    owner=$PR_OWNER
    if list_has "$PR_REVIEWED" "$owner"; then
      printf '  %s %s (review recorded)\n' "$url" "$owner"
    else
      printf '  %s %s (awaiting review)\n' "$url" "$owner"
    fi
    open=$((open + 1))
  done < <(ledger_rows | awk -F '\t' '$2 != "-" {print $2}' | awk '!seen[$0]++')
  [ "$open" -gt 0 ] || printf '  none\n'
}

cmd_check() {
  local url ledger_only=0 comments logins login service found='' leaks='' released
  [ "$#" -ge 1 ] || fail "check needs a PR URL"
  url=$(validate_pr_url "$1")
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ledger-only) ledger_only=1 ;;
      *) fail "unknown check option: $1" ;;
    esac
    shift
  done

  fold_pr_state "$url"
  if [ -n "$PR_OWNER" ]; then
    printf 'owner: %s\n' "$PR_OWNER"
  elif [ -n "$PR_REFUSED$PR_EXHAUSTED" ]; then
    released=''
    [ -z "$PR_REFUSED" ] || released="refused: $PR_REFUSED"
    [ -z "$PR_EXHAUSTED" ] || released="${released:+$released; }exhausted: $PR_EXHAUSTED"
    printf 'owner: none (%s)\n' "$released"
  else
    printf 'owner: none recorded\n'
  fi

  if [ "$ledger_only" = 1 ]; then
    printf 'evidence: not read (--ledger-only)\n'
    [ -n "$PR_OWNER" ] || refuse "no review owner is recorded for $url"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || fail "gh is required to read PR comment evidence (or pass --ledger-only)"
  comments=$(gh pr view "$url" --json comments \
    --jq '.comments[].author.login' 2>/dev/null) \
    || fail "could not read comments for $url"

  for service in coderabbit greptile devin; do
    logins=$(service_logins "$service")
    while IFS= read -r login; do
      [ -n "$login" ] || continue
      if printf '%s\n' "$comments" | grep -qix -- "$login" ||
        printf '%s\n' "$comments" | grep -qix -- "$login\[bot\]"; then
        list_add found "$service"
        break
      fi
    done <<EOF
$logins
EOF
  done

  printf 'evidence: %s\n' "${found:-none}"

  # A service this PR released through a refusal or an exhaustion has a comment
  # here for it - CodeRabbit delivers its rate-limit notice as one, and a
  # released owner leaves its own review behind - so its evidence is explained
  # rather than leaked. Every other non-owner with evidence is a leak.
  for service in $found; do
    if [ "$service" != "$PR_OWNER" ] && ! list_has "$PR_UNAVAILABLE" "$service"; then
      list_add leaks "$service"
    fi
  done

  if [ -n "$leaks" ]; then
    refuse "leak: $leaks reviewed $url, which is owned by ${PR_OWNER:-no recorded service}"
  fi
  if [ -z "$PR_OWNER" ]; then
    refuse "no review owner is recorded for $url"
  fi
  printf 'verdict: consistent\n'
}

# --- entry point ------------------------------------------------------------

[ "$#" -ge 1 ] || { usage >&2; exit 1; }
COMMAND=$1
shift
case "$COMMAND" in
  choose) cmd_choose "$@" ;;
  record) cmd_record "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  status) cmd_status "$@" ;;
  check) cmd_check "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
