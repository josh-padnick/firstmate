#!/usr/bin/env bash
# fm-dashboard.sh - the captain's mission-control dashboard.
#
# Two outputs, in this order of authority:
#   1. data/mission-control.json - the STRUCTURED STATE DOCUMENT, schema
#      `fm-mission-control.v1`. This is the contract. A later live server can
#      serve exactly this object, so nothing built here is thrown away.
#   2. data/mission-control.html - a RENDERING of that document, and only of
#      that document. Self-contained and offline: no network, no external
#      assets, no fetch. It embeds the exact state document it was rendered
#      from in a <script type="application/json"> block.
#
# This command does not parse fleet state itself. It projects
# bin/fm-fleet-snapshot.sh's canonical `fm-fleet-snapshot.v1` object, the same
# way bin/fm-bearings-snapshot.sh projects it for a different question. Current
# state comes from that snapshot's current_state (bin/fm-crew-state.sh), activity
# feeds from its bounded status_log.events, decisions from its normalized backlog
# records. It is read-only over fleet state: no session lock, no wake drain, no
# fleet mutation. It writes only its own outputs and PR cache.
#
# LOCAL-ONLY by default: a normal regeneration makes ZERO network calls, so it is
# cheap enough to run on a timer. Live PR data (title, draft, merged, check
# rollup) is fetched ONLY by --refresh-prs, which writes state/dashboard-prs.json
# through `gh` - the same tool bin/fm-pr-poll.sh and bin/fm-pr-check.sh use for
# machine-readable PR reads. Every later regeneration reads that cache and
# publishes its age; past FM_DASHBOARD_PR_TTL seconds (default 900) the checks
# read stale and a notice says so, because a dashboard that quietly shows old
# check results is worse than one that admits it did not look.
#
# The page updates itself with <meta http-equiv="refresh">, and the generator
# must be running (--watch) for that reload to show anything new. A file:// page
# cannot poll for JSON - Chrome blocks both fetch and XMLHttpRequest from a
# file:// origin - so a whole-page reload is the honest offline mechanism.
# Per-panel scroll positions are preserved across it in sessionStorage.
#
# Usage:
#   fm-dashboard.sh                      write both outputs into $FM_HOME/data
#   fm-dashboard.sh --json               print the state document to stdout
#   fm-dashboard.sh --render <file.json> print HTML for that state document
#   fm-dashboard.sh --refresh-prs        refresh the PR cache first, then write
#   fm-dashboard.sh --watch [secs]       regenerate every <secs> (default 60)
#
# Flags:
#   --json                 print the state document to stdout; write nothing
#   --render <file>        render HTML from an existing state document to stdout
#   --out-dir <dir>        write outputs here instead of $FM_HOME/data
#   --refresh <secs>       page self-refresh interval to publish (default 60)
#   --refresh-prs          make the one network pass that refreshes the PR cache
#   --watch [secs]         loop, regenerating every <secs> (default --refresh)
#   --snapshot <file>      project this captured fleet snapshot instead of
#                          running a fresh one (tests, replay, Phase 2 reuse)
#
# Environment:
#   FM_DASHBOARD_PR_TTL       seconds before cached PR data reads stale (900)
#   FM_DASHBOARD_COMPLETED    landed rows the document carries (20); the page
#                             shows six and puts the rest behind "View N older"
#   FM_DASHBOARD_NOW          ISO-8601 UTC override for a deterministic stamp
#
# ---------------------------------------------------------------------------
# Schema `fm-mission-control.v1`
#
# {
#   schema, generated (UTC ISO-8601), generated_display (local, human),
#   fm_home, refresh_seconds,
#   source: {
#     fleet_snapshot: {schema, generated},
#     pr_data: {present, fetched, age_seconds, stale, ttl_seconds, records}
#   },
#   counts: {inbox, mine, worker_turn, external_turn, merge_queue,
#            awaiting_captain, ui, plan, decision, decisions, in_flight,
#            in_flight_live, completed, notices},
#
# The page renders this document TWICE, as two views the captain can switch
# between: the BOARD - one dominant "Needs your attention" queue over compact
# active-work and landed summaries, with detail behind expansion - and an
# experimental inbox - one list of what is his
# turn, filtered by type and by turn, whose count is the size of the queue and
# shrinks as he works through it. Both views read the same arrays, so they can
# never disagree about what is waiting.
#
#   TURN - carried by every merge_queue, awaiting_captain and in_flight item:
#     {turn: captain|worker|external, waiting_for, turn_reason, headline,
#      action: merge|look|read|decide|null, since, since_source: backlog|status-log|null,
#      since_epoch, age_seconds,
#      activity: {text, source: run-step|status-log|state, state},
#      attended: true|false|null, attended_by: pipeline|worker|null,
#      attended_evidence: run-step|live-endpoint|no-endpoint|idle-endpoint|unverified}
#     ATTENDANCE answers "is a fix actually in progress?", because blocked-and-
#     being-worked and blocked-and-stalled are different situations for the
#     captain. `true` needs positive evidence - an attributed pipeline run that
#     is running, or a worker the backend reports busy; a session that merely
#     exists is not someone working. `false` means nobody is on it, which is
#     said outright rather than implied by silence. `null` means we could not
#     verify, and is rendered as its own state so neither answer is guessed.
#     Items also carry `stuck`: true when a worker reported `blocked:` (it needs
#     help) as opposed to `needs-decision:` (it is waiting on the captain by
#     design). Stuck work sorts ahead of merely old work.
#     `age_seconds` exists so a renderer can say "12 min ago" without parsing
#     dates: jq 1.6's own date functions are an hour out under daylight time, so
#     every epoch here is resolved in shell.
#     `headline` is the one line that says which of the two situations this is -
#     "Yours to review and merge" or "Blocked on <the concrete thing>" - so the
#     difference is read, never inferred.
#     `activity` is what is happening to this work right now, in the captain's
#     nouns. Its preference order is most-specific-first: an attributed pipeline
#     step, then the worker's own latest status words (which is where rebasing,
#     fixing conflicts and answering review comments actually come from), then
#     the bare state. `source` says which, so a busy pane is never reported as
#     validation. Phase 2 pushes transitions of this field as events.
#     `turn` is whose move it is, derived from what the fleet actually shows and
#     never from which list the item sits in. An open pull request whose lane is
#     still running its pipeline is the WORKER's turn; checks that have not
#     reported are EXTERNAL; a parked lane or an open question is the CAPTAIN's.
#     Putting something in the captain's queue that he cannot act on is the one
#     failure this field exists to prevent.
#     `action` is what he would do about it, and is null unless it is his turn.
#     `since` prefers the durable backlog date and falls back to when the status
#     event was recorded; `since_source` says which, so neither is mistaken for
#     the other.
#     THE INBOX is derived, not stored: every item across those three arrays
#     whose turn is `captain`, deduped by id (one lane blocked on one question is
#     one thing to do). counts.inbox is its size.
#
#   merge_queue[]: one open pull request, whoever's turn it is.
#     {id, title, url, number, repo, project, status: ready|held,
#      checks: {state: passing|failing|pending|none|unknown, summary, source},
#      blockers[]: {kind: checks|decision|worker|depends-on|hold|draft, text},
#      source: task-meta|backlog|forge, + TURN}
#     status is `held` exactly when blockers is non-empty, so "what blocks it"
#     is never a colour the captain has to interpret.
#
#   awaiting_captain[]: one artifact or question waiting on the captain, TYPED,
#     because reading a plan, looking at a UI, and answering a question are
#     different work.
#     {id, type: ui|plan|decision, kind, title, note, link,
#      link_kind: file|http|null, project,
#      source: status-decision|backlog-hold|scout-report,
#      decisions[]: {id, key, question, recommendation, recommendation_source,
#                    reasoning},
#      decision_count, recommended_count, evidence, + TURN}
#     Every decision carries the answer a plan already recommended, so it can be
#     answered here instead of hunted for. `recommendation` is parsed from the
#     hold text a plan wrote ("Option A, recommended: ..."), read from the raw
#     backlog row because the canonical parser stops hold_reason at the first
#     comma. Where no recommendation is extractable, `reasoning` carries the
#     hold's own argument so the item is still actionable rather than a prompt
#     to go research.
#     Typing rule, in order: no artifact at all is a `decision`; a .md document
#     is a `plan`; scout work is a `plan` even when its deliverable renders as a
#     page, because scouts produce knowledge to read; a rendered page from ship
#     work is a `ui` to look at. The extension alone cannot decide this - plans
#     render to HTML too - so the dispatch kind is the durable signal.
#     A link is published only when it resolves to a file this home really has.
#     The decisions[] arrays, flattened, ARE the decision queue: the renderer
#     shows one array as both a typed review list and a decision list rather
#     than deriving two sets that can disagree.
#
#   in_flight[]: one live lane and its own activity feed.
#     {id, title, project, kind, mode, state, state_source, detail, live,
#      needs_captain, pr: {url, number}|null,
#      feed[]: {state, note, raw} newest first, + TURN}
#     `feed` is the history - "we did this, then that" - while `activity` from
#     TURN is the single thing happening now. Both come from the same status
#     event stream and neither is current-state truth on its own.
#     Persistent secondmate lanes are deliberately excluded: an idle secondmate
#     is healthy, and drawing it as a stalled lane would misreport it.
#
#   completed[]: {id, title, when, verb, project, url, source}
#   notices[]: {kind, text} - anything the captain would otherwise have to
#     discover by clicking: stale PR data, broken inventory, unreadable homes,
#     completed rows dropped by the retention cap.
# }
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PR_CACHE="$STATE/dashboard-prs.json"
SCHEMA="fm-mission-control.v1"

PR_TTL=${FM_DASHBOARD_PR_TTL:-900}
COMPLETED_MAX=${FM_DASHBOARD_COMPLETED:-20}

MODE=files
OUT_DIR=""
RENDER_FROM=""
SNAPSHOT_FILE=""
REFRESH=60
REFRESH_PRS=0
WATCH=0
WATCH_SECS=""

usage() {
  sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

die() { printf 'fm-dashboard: %s\n' "$1" >&2; exit 2; }

require_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive integer" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) MODE=json ;;
    --render)
      [ $# -ge 2 ] || die "--render needs a state document path"
      MODE=render; RENDER_FROM=$2; shift
      ;;
    --out-dir)
      [ $# -ge 2 ] || die "--out-dir needs a directory"
      OUT_DIR=$2; shift
      ;;
    --refresh)
      [ $# -ge 2 ] || die "--refresh needs seconds"
      REFRESH=$2; shift
      ;;
    --refresh-prs) REFRESH_PRS=1 ;;
    --snapshot)
      [ $# -ge 2 ] || die "--snapshot needs a snapshot JSON path"
      SNAPSHOT_FILE=$2; shift
      ;;
    --watch)
      WATCH=1
      case "${2:-}" in
        ''|-*) : ;;
        *) WATCH_SECS=$2; shift ;;
      esac
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

require_int --refresh "$REFRESH"
require_int FM_DASHBOARD_PR_TTL "$PR_TTL"
require_int FM_DASHBOARD_COMPLETED "$COMPLETED_MAX"
[ -n "$WATCH_SECS" ] || WATCH_SECS=$REFRESH
require_int --watch "$WATCH_SECS"
[ "$WATCH" -eq 1 ] && REFRESH=$WATCH_SECS
[ -n "$OUT_DIR" ] || OUT_DIR=$DATA

command -v jq >/dev/null 2>&1 || die "jq not found"

TMPWORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") || die "cannot create temp dir"
cleanup() { rm -rf "$TMPWORK"; }
trap cleanup EXIT INT TERM

now_utc() {
  if [ -n "${FM_DASHBOARD_NOW:-}" ]; then
    printf '%s' "$FM_DASHBOARD_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# TZ=UTC is load-bearing, and so is not using jq here. BSD date's `-j -f` parses
# in the zone from the environment - `-u` only affects output - and jq 1.6's
# fromdateiso8601 applies local daylight rules to a Z timestamp. Either one puts
# the captain's stamp an hour out during DST. Setting TZ for the parse is the one
# form that agrees with the wall clock on both platforms.
iso_to_epoch() {  # <iso8601-utc> -> epoch seconds, or empty
  [ -n "${1:-}" ] || return 0
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || true
}

# Human stamp in the captain's own timezone, derived from the same instant as
# the machine field so the two can never disagree.
display_stamp() {  # <iso8601-utc>
  local epoch
  epoch=$(iso_to_epoch "$1")
  [ -n "$epoch" ] || { printf '%s' "$1"; return 0; }
  date -r "$epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
    || date -d "@$epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
    || printf '%s' "$1"
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

capture_snapshot() {  # -> path to fleet snapshot JSON
  local out=$TMPWORK/snapshot.json
  if [ -n "$SNAPSHOT_FILE" ]; then
    [ -f "$SNAPSHOT_FILE" ] || die "snapshot not found: $SNAPSHOT_FILE"
    cp "$SNAPSHOT_FILE" "$out"
  else
    FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$out" \
      || die "fleet snapshot failed"
  fi
  printf '%s' "$out"
}

# Openable artifacts this home actually has on disk. A link is published only
# when it resolves to one of these, so the dashboard never hands the captain a
# path that fails to open.
artifact_index() {  # -> path to JSON array of absolute paths
  local out=$TMPWORK/artifacts.json
  if [ -d "$DATA" ]; then
    LC_ALL=C find "$DATA" -maxdepth 3 -type f \( -name '*.html' -o -name '*.md' \) 2>/dev/null \
      | sort | jq -Rn '[inputs]' > "$out"
  else
    printf '[]' > "$out"
  fi
  printf '%s' "$out"
}

# One network pass for PR data. It reads every PR this home has a local record
# of, AND lists open PRs for every repository the fleet works in, because a PR
# whose lane has already been cleaned up is still a PR the captain has to land -
# local records alone would silently shorten the merge queue.
# A single unreachable PR or repository is recorded and skipped, never fatal.
refresh_pr_cache() {  # <snapshot-json>
  local snap=$1 url repo record records='[]' fetched urls
  command -v gh >/dev/null 2>&1 || {
    printf 'fm-dashboard: gh not found; PR cache not refreshed\n' >&2
    return 1
  }
  fetched=$(now_utc)

  urls=$TMPWORK/pr-urls
  jq -r '
    [ (.tasks[]? | .pr.url // empty),
      (.backlog.records[]? | select(.state != "done") | .pr_url // empty) ]
    | unique | .[]' "$snap" > "$urls"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    gh pr list --repo "$repo" --state open --limit 50 --json url 2>/dev/null \
      | jq -r '.[].url' >> "$urls" || true
  done <<EOF
$(jq -r '[ .backlog.records[]? | .repo // empty ] | map(select(test("/"))) | unique | .[]' "$snap")
EOF

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    record=$(gh pr view "$url" \
      --json number,title,url,state,isDraft,statusCheckRollup 2>/dev/null) || record=""
    if [ -z "$record" ]; then
      record=$(jq -n --arg url "$url" '{url:$url,reachable:false}')
    else
      record=$(printf '%s' "$record" | jq --arg url "$url" '
        def rollup_state:
          if ((. // []) | length) == 0 then "none"
          elif any(.[]; ((.conclusion // "")
                 | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"))
                 or ((.state // "") | IN("FAILURE","ERROR"))) then "failing"
          elif any(.[]; ((.status // "COMPLETED") != "COMPLETED")
                 or ((.state // "SUCCESS") | IN("PENDING","EXPECTED"))) then "pending"
          else "passing" end;
        (.statusCheckRollup // []) as $r
        | {
            url: $url,
            reachable: true,
            number: .number,
            title: .title,
            state: (.state // "UNKNOWN"),
            draft: (.isDraft // false),
            merged: ((.state // "") == "MERGED"),
            checks: {
              state: ($r | rollup_state),
              summary: (
                "\([$r[] | select(((.conclusion // .state) // "")
                    | IN("SUCCESS","NEUTRAL","SKIPPED"))] | length) passed, "
                + "\([$r[] | select(((.conclusion // .state) // "")
                    | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","ERROR"))] | length) failed, "
                + "\($r | length) total")
            }
          }')
    fi
    records=$(printf '%s' "$records" | jq --argjson r "$record" '. + [$r]')
  done < <(sort -u "$urls")
  mkdir -p "$STATE"
  printf '%s' "$records" \
    | jq --arg fetched "$fetched" '{fetched:$fetched,records:.}' > "$PR_CACHE.tmp" \
    && mv "$PR_CACHE.tmp" "$PR_CACHE"
}

pr_cache_json() {  # -> path to PR cache JSON (empty shape when absent)
  local out=$TMPWORK/prs.json
  if [ -f "$PR_CACHE" ] && jq -e . "$PR_CACHE" >/dev/null 2>&1; then
    cp "$PR_CACHE" "$out"
  else
    printf '{"fetched":null,"records":[]}' > "$out"
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Projection: fm-fleet-snapshot.v1 -> fm-mission-control.v1
# ---------------------------------------------------------------------------

write_projection_program() {  # -> path to the jq program
  local prog=$TMPWORK/project.jq
  cat > "$prog" <<'JQ'
def nn: if . == null or . == "" then null else . end;
def trim: if . == null then null else (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) end;
def clip($n):
  if . == null then null
  elif (. | length) <= $n then .
  else (.[0:$n] | sub("[[:space:]]+$"; "")) + "…" end;
def dedupe: reduce .[] as $x ([]; if (. | index([$x])) then . else . + [$x] end);

# Local artifact paths a worker named in its own words, resolved against this
# home and kept only when the file exists. Order of appearance is preference
# order, so the most recently named artifact wins.
def local_links($index; $home):
  (. // "")
  | [ match("(?:file://)?(?:/|(?:data|projects)/)[^[:space:],;)\\]\"'<>]*\\.(?:html|md)"; "g").string ]
  | map(sub("^file://"; ""))
  | map(if startswith("/") then . else ($home + "/" + .) end)
  | map(select(. as $p | $index | index([$p])));

def http_links:
  (. // "") | [ match("https?://[^[:space:],;)\\]\"'<>]+"; "g").string ];

# Choosing the one artifact to hand the captain, in this order:
#   1. a rendered page in the work's OWN directory that a worker also named,
#   2. any rendered page in its own directory,
#   3. a rendered page it named somewhere else (lanes here render slices into a
#      shared review document, so this is a real case, not a mistake),
#   4. a document it named, then its own report, then an external URL.
# Something to LOOK AT outranks something to read whenever both exist, because
# that is the more specific ask.
def pick_link($index; $home; $origin):
  ([ .[] | local_links($index; $home) ] | flatten | dedupe) as $named
  | ($index | map(select(startswith($home + "/data/" + $origin + "/")))) as $own
  | ($own | map(select(endswith(".html")))) as $own_html
  | (($named | map(select(endswith(".html"))) | map(select(. as $p | $own_html | index([$p]))) | first)
     // ($own_html | first)
     // ($named | map(select(endswith(".html"))) | first)
     // ($named | map(select(endswith(".md"))) | first)
     // ($own | map(select(endswith("/report.md"))) | first)
     // ([ .[] | http_links ] | flatten | dedupe | first)
     // null);

def link_kind($link):
  if $link == null then null
  elif ($link | startswith("http")) then "http"
  else "file" end;

# Reading a plan and looking at a UI are different work, and in this fleet the
# file extension cannot tell them apart: plans are rendered to HTML too. The
# durable signal is what the work was dispatched to produce. Scout work produces
# knowledge, so its deliverable is something to READ even when it renders as a
# page; ship work produces a product change, so its rendered page is something
# to LOOK AT. A document with no rendered form is always a read, and an ask with
# no artifact at all is a plain decision.
def type_for($link; $kind):
  if $link == null then "decision"
  elif ($link | endswith(".md")) then "plan"
  elif $kind == "scout" then "plan"
  elif ($link | endswith(".html")) then "ui"
  else "decision" end;

def as_file_url($link):
  if $link == null then null
  elif ($link | startswith("http")) then $link
  else "file://" + $link end;

# Whose turn it is, and when it became that turn. Derived from what the fleet
# actually shows, never from which list an item happens to sit in: an open pull
# request whose lane is still running its pipeline is the WORKER's turn, and
# saying otherwise puts something in the captain's queue that he cannot act on.
def turn_of($who; $waiting; $reason; $action):
  {turn: $who, waiting_for: $waiting, turn_reason: $reason, action: $action}
  # One line that says which of the two situations this is, so the captain never
  # has to infer "mine" from "not blocked". Rendered as-is.
  + {headline:
      (if $who == "captain"
       then (if $action == "merge" then "Yours to review and merge"
             elif $action == "look" then "Yours to look at"
             elif $action == "read" then "Yours to read"
             else "Yours to decide" end)
       else "Blocked on " + $waiting end)};

# The concrete thing happening to this work right now, in the captain's nouns.
# Preference order is most-specific-first: the pipeline's own step when a run is
# attributed, then the worker's latest words - which is where "rebasing",
# "fixing merge conflicts" and "responding to review comments" actually come
# from - and only then the bare state word.
#
# The run-step phrases match the detail vocabulary bin/fm-crew-state.sh actually
# emits ("validating (fixing)", "ci running", "parked at <gate>") rather than
# invented labels, so "a fix is running" is never guessed from a busy pane.
def activity_of($task):
  ($task.current_state.state // "unknown") as $st
  | ($task.current_state.source // "none") as $src
  | ($task.current_state.detail // "") as $detail
  | (($task.paths.status_log.events // [])[0] // null) as $latest
  | if $src == "run-step" and $st == "working"
    then {text: (if ($detail | test("fixing"; "i"))
                 then "fixing the defects review found"
                 elif ($detail | test("^ci |ci running|checks"; "i"))
                 then "waiting on CI checks"
                 else "running validation" end),
          source: "run-step"}
    elif $src == "run-step" and $st == "parked"
    then {text: (if ($detail | test("ask-user"; "i"))
                 then "waiting on a decision only you can make"
                 else "waiting at a review gate" end),
          source: "run-step"}
    elif $src == "run-step" and $st == "failed"
    then {text: "validation stopped", source: "run-step"}
    elif $latest != null and ($latest.note // "") != ""
    then {text: ($latest.note | clip(160)), source: "status-log"}
    elif $st == "done" then {text: "finished, waiting to land", source: "state"}
    else {text: ("no recent activity recorded"), source: "state"} end
  | . + {state: $st};

# Is anyone actually on this right now? Blocked-and-being-fixed and
# blocked-and-stalled are different situations for the captain, and silence
# about ownership is the failure mode - so `attended: null` means we could not
# verify and must SAY so, never quietly imply either answer.
#
# Positive attendance needs positive evidence: an attributed pipeline run that
# is actually running, or a worker the backend reports busy. A session that
# merely exists is not someone working.
def attendance_of($task):
  ($task.current_state.state // "unknown") as $st
  | ($task.current_state.source // "none") as $src
  | ($task.endpoint.exists) as $endpoint
  | if $src == "run-step" and $st == "working"
    then {attended: true, attended_by: "pipeline", attended_evidence: "run-step"}
    elif $src == "pane" and $st == "working"
    then {attended: true, attended_by: "worker", attended_evidence: "live-endpoint"}
    elif $endpoint == false
    then {attended: false, attended_by: null, attended_evidence: "no-endpoint"}
    elif $endpoint == null
    then {attended: null, attended_by: null, attended_evidence: "unverified"}
    else {attended: false, attended_by: null, attended_evidence: "idle-endpoint"}
    end;

# The recommended answer a plan already stated, so a decision can be answered
# here instead of hunted for. Real holds phrase it as "Option A, recommended: X",
# and anything after the next option label belongs to that other option.
def recommendation_of($text):
  ($text // "")
  | if (test("recommend(ed|ation)?s?:"; "i") | not) then null
    else
      ((capture("(Option[[:space:]]+(?<label>[A-Za-z0-9]+)[,:]?[[:space:]]*)?recommend(ed|ation)?s?:[[:space:]]*(?<rec>.+)$"; "i")) // null)
      | if . == null then null
        else ((if (.label // "") != "" then "Option " + .label + ": " else "" end)
              + (.rec | sub("[[:space:]]+Option[[:space:]]+[A-Za-z0-9]+[:,].*$"; "")))
        end
    end;

# How long this has been waiting, plus the age the renderer turns into "12 min
# ago" or "yesterday". Epochs are resolved in bash, never in jq: jq 1.6's
# strptime/mktime and fromdateiso8601 both apply local daylight rules, which is
# the same hour-out bug already recorded for the generated stamp.
def since_of($backlog_date; $id):
  (if ($backlog_date // "") != ""
   then {since: $backlog_date, since_source: "backlog",
         since_epoch: ($dates[0][$backlog_date] // null)}
   elif ($mtimes[0][$id] // null) != null
   then {since: ($mtimes[0][$id] | todate), since_source: "status-log",
         since_epoch: $mtimes[0][$id]}
   else {since: null, since_source: null, since_epoch: null} end)
  | . + {age_seconds: (if .since_epoch == null then null
                       else ($now_epoch - .since_epoch) end)};

$snap[0] as $s
| $prs[0] as $prcache
| $artifacts[0] as $index
| ($s.backlog.records // []) as $backlog
| ($s.tasks // []) as $tasks
| ($prcache.records // []) as $prrecords

# ---- PR data freshness ------------------------------------------------------
| (if $prcache.fetched == null then null else ($now_epoch - $fetched_epoch) end) as $pr_age
| {
    present: ($prcache.fetched != null),
    fetched: $prcache.fetched,
    age_seconds: $pr_age,
    stale: (($prcache.fetched == null) or (($pr_age // 0) > $ttl)),
    ttl_seconds: $ttl,
    records: ($prrecords | length)
  } as $pr_data

# ---- decision records the captain owns, grouped by the work they came from --
| ([ $backlog[]
     | select(.structured == true and .state != "done" and .captain_actionable == true)
     | . as $r
     | ((($r.body_lines // [])[] | capture("^Origin:[[:space:]]*(?<o>[^[:space:]]+)").o)
        // ($r.id | sub("-decision-.*$"; ""))) as $origin
     | ((($r.body_lines // [])[] | capture("^Decision key:[[:space:]]*(?<k>[^[:space:]]+)").k)
        // ($r.id | capture("-decision-(?<k>.*)$").k)
        // "default") as $key
     # The canonical backlog parser stops hold_reason at the first comma, which
     # is exactly where a stated recommendation usually still lies ahead. The
     # raw row keeps the whole hold, so the full text is recovered from there
     # and hold_reason is only the fallback.
     | ((($r.raw // "")
         | (capture("\\(hold:[[:space:]]*(?<h>.*?)\\)[[:space:]]*\\(hold-kind"; "") // null)
         | if . == null then null else .h end)
        // ($r.hold_reason | nn)
        // "") as $hold
     | ([$hold, ($r.body_lines // [] | join(" "))]
        | map(select(. != null and . != "")) | join(" ")) as $text
     | {origin: $origin, key: $key, id: $r.id,
        question: (($r.title | nn) // ($r.hold_reason | nn) // $r.id),
        stuck: false,
        recommendation: recommendation_of($text),
        recommendation_source: (if recommendation_of($text) == null then null else "hold" end),
        context: (($hold | nn) // ($r.hold_reason | nn)),
        since: ($r.since | nn),
        repo: ($r.repo | nn)}
   ]) as $held

# ---- decisions a worker still has open in its own status stream -------------
| ([ $tasks[]
     | . as $t
     | (.hints.open_decisions // [])[]
     | {origin: $t.id, key: .key, id: ($t.id + ":" + .key),
        question: (.summary | trim | clip(240)),
        recommendation: recommendation_of(.summary),
        recommendation_source: (if recommendation_of(.summary) == null then null else "status" end),
        context: null, since: null, repo: ($t.backlog.repo | nn),
        # A `blocked:` report means the worker is stuck and needs help; a
        # `needs-decision:` is waiting on the captain by design. Only the
        # former makes "is anyone on it?" the deciding question.
        stuck: (.verb == "blocked")}
   ]
   # A decision firstmate already filed as a durable captain hold is the same
   # decision; the durable record wins so the queue never double-counts it.
   | map(select(. as $d
       | ($held | any(.origin == $d.origin and (.key == $d.key or $d.key == "default"))) | not))
  ) as $open_status

| ($held + $open_status) as $all_decisions
| ($all_decisions | map(.origin) | dedupe) as $origins

# ---- one typed item per origin ---------------------------------------------
| [ $origins[]
    | . as $origin
    | ($all_decisions | map(select(.origin == $origin))) as $ds
    | ($tasks | map(select(.id == $origin)) | first) as $task
    | ($backlog | map(select(.id == $origin)) | first) as $brec
    | ([ ($ds[] | .question), ($ds[] | .context // empty),
         ($task.hints.open_decisions // [] | .[] | .summary),
         ($task.paths.status_log.events // [] | .[] | .raw),
         ($task.paths.report.path // empty),
         ($s.scout_reports // [] | map(select(.id == $origin)) | .[0].path // empty)
       ] | map(select(. != null))) as $texts
    | ($texts | pick_link($index; $home; $origin)) as $link
    | (($task.kind | nn) // ($brec.kind | nn)
       // ($s.scout_reports // [] | map(select(.id == $origin)) | .[0].kind | nn)
       // "ship") as $kind
    | {
        id: $origin,
        type: type_for($link; $kind),
        kind: $kind,
        # The work's own name, never a decision question standing in for it: a
        # question is what to answer, not what the item is.
        title: (($task.backlog.title | nn) // ($brec.title | nn) // $origin),
        note: (($ds[0].question | nn) // ($ds[0].context | nn) // null),
        link: as_file_url($link),
        link_kind: link_kind($link),
        project: (($task.backlog.repo | nn) // ($brec.repo | nn) // ($ds[0].repo | nn)),
        source: (if ($ds | any(.context != null or (.id | test(":") | not)))
                 then "backlog-hold" else "status-decision" end),
        decisions: [ $ds[] | {id: .id, key: .key, question: .question,
                              recommendation: .recommendation,
                              recommendation_source: .recommendation_source,
                              # With no stated recommendation, the reasoning that
                              # raised the question is what keeps the item
                              # answerable in place rather than research to do.
                              reasoning: (if .recommendation == null then (.context | nn) else null end)} ],
        decision_count: ($ds | length),
        stuck: (($ds | map(.stuck // false) | any)),
        recommended_count: ([ $ds[] | select(.recommendation != null) ] | length),
        evidence: (($task.hints.last_event_text | nn) // ($brec.raw | nn) // null)
      }
    # An ask whose lane went back to work is not the captain's turn yet, however
    # it is listed: the worker has moved past it.
    + {activity: activity_of($task)}
    + attendance_of($task)
    + (if ($task.current_state.state // "") == "working"
       then turn_of("worker"; "the worker finishing this pass";
                    "its lane is working again"; null)
       else turn_of("captain";
                    (if $link == null then "your decision"
                     elif type_for($link; $kind) == "ui" then "you to look at it"
                     else "you to read it" end);
                    "waiting on you since it was raised";
                    (if $link == null then "decide"
                     elif type_for($link; $kind) == "ui" then "look"
                     else "read" end))
       end)
    + since_of((($ds | map(.since) | map(select(. != null)) | first)
                // ($brec.since | nn)); $origin)
  ] as $decision_items

# ---- finished work whose deliverable is a document nobody has read yet ------
| [ $tasks[]
    | select(.kind == "scout")
    | select((.hints.open_decisions // []) | length == 0)
    | select(.paths.report.present == true)
    | select(.current_state.state == "done")
    | select((.backlog.state // "") != "done")
    # An origin that already has an open decision is one ask, not two.
    | select(. as $t | ($decision_items | any(.id == $t.id)) | not)
    | . as $t
    | ([ $t.paths.report.path, ($t.paths.status_log.events // [] | .[] | .raw) ]
       | map(select(. != null))) as $texts
    | ($texts | pick_link($index; $home; $t.id)) as $link
    | (($t.kind | nn) // "scout") as $kind
    | {
        id: $t.id,
        type: type_for($link; $kind),
        kind: $kind,
        title: (($t.backlog.title | nn) // $t.id),
        note: (($t.paths.status_log.last_event.note | nn) | trim | clip(240)),
        link: as_file_url($link),
        link_kind: link_kind($link),
        project: ($t.backlog.repo | nn),
        source: "scout-report",
        decisions: [],
        decision_count: 0,
        recommended_count: 0,
        evidence: ($t.hints.last_event_text | nn)
      }
    + {activity: activity_of($t)}
    + attendance_of($t)
    + turn_of("captain";
              (if type_for($link; $kind) == "ui" then "you to look at it"
               else "you to read it" end);
              "its deliverable is finished and unread";
              (if type_for($link; $kind) == "ui" then "look" else "read" end))
    + since_of(($t.backlog.since | nn); $t.id)
  ] as $report_items

| (($decision_items + $report_items)
   | sort_by([(if .type == "ui" then 0 elif .type == "plan" then 1 else 2 end),
              (0 - .decision_count), .id])) as $awaiting

# ---- open pull requests -----------------------------------------------------
| ([ ($tasks[] | select(.pr.url != null)
      | {url: .pr.url, id: .id, source: "task-meta", task: .}),
     ($backlog[] | select(.state != "done" and .pr_url != null)
      | {url: .pr_url, id: .id, source: "backlog", task: null}),
     # An open pull request whose lane has already been cleaned up is still
     # waiting on the captain, so a refreshed cache can contribute rows no
     # local record mentions.
     ($prrecords[] | select((.reachable // false) and ((.merged // false) | not))
      | {url: .url, id: (.url | capture("/(?<n>[0-9]+)$").n // .url),
         source: "forge", task: null})
   ]
   | group_by(.url) | map(.[0])) as $pr_refs

| [ $pr_refs[]
    | . as $ref
    | ($prrecords | map(select(.url == $ref.url)) | first) as $live
    | ($ref.task) as $task
    | (($task.backlog) // ($backlog | map(select(.id == $ref.id)) | first)) as $brec
    | select(($live.merged // false) == false)
    | select((($live.state // "OPEN") | IN("MERGED","CLOSED")) | not)
    | ([
        (if ($live.checks.state // "") == "failing"
         then {kind: "checks",
               text: ("checks failing" + (if ($live.checks.summary | nn)
                      then " (" + $live.checks.summary + ")" else "" end))}
         else empty end),
        (if ($live.checks.state // "") == "pending"
         then {kind: "checks", text: "checks still running"} else empty end),
        (if (($live.checks.state // "unknown") == "unknown")
         then {kind: "checks",
               text: (if $live == null then "checks not fetched"
                      else "check status unconfirmed" end)}
         else empty end),
        (if ($live.draft // false) then {kind: "draft", text: "still a draft"}
         else empty end),
        (if ($task.current_state.state // "") | IN("blocked","failed")
         then {kind: "worker",
               text: (($task.current_state.detail | nn | clip(160))
                      // ("the lane is " + $task.current_state.state))}
         else empty end),
        ($all_decisions | map(select(.origin == $ref.id)) | .[]
         | {kind: "decision", text: ("waiting on your decision: "
                                     + (.question | trim | clip(160)))}),
        ($brec.unresolved_blocker_ids // [] | .[]
         | {kind: "depends-on", text: ("waits on " + .)}),
        (if ($brec.hold_reason | nn)
         then {kind: "hold", text: ($brec.hold_reason | clip(200))} else empty end)
      ]) as $blockers
    | {
        id: $ref.id,
        title: (($brec.title | nn) // ($live.title | nn)
                // ("PR " + ($ref.url | capture("/(?<n>[0-9]+)$").n // ""))),
        url: $ref.url,
        number: (($live.number) // (($ref.url | capture("/(?<n>[0-9]+)$").n // "0") | tonumber)),
        repo: ($brec.repo | nn),
        project: (($task.project | nn) // ($brec.repo | nn)),
        status: (if ($blockers | length) > 0 then "held" else "ready" end),
        checks: {
          state: (if $live == null then "unknown" else ($live.checks.state // "unknown") end),
          summary: ($live.checks.summary // null),
          source: (if $live == null then "not-fetched" else "pr-cache" end)
        },
        blockers: $blockers,
        source: $ref.source
      }
    + {activity: activity_of($task)}
    + attendance_of($task)
    # Whose turn a pull request is has nothing to do with it being open. A lane
    # still running its pipeline owes the next move, checks that have not
    # reported are owed by CI, and only a PR nobody else is working on is
    # actually the captain's to land.
    + (if ($blockers | any(.kind == "decision"))
       then turn_of("captain"; "your decision"; "its lane is waiting on you"; "decide")
       elif ($task.current_state.state // "") == "parked"
       then turn_of("captain"; "your decision at a gate"; "its run is parked"; "decide")
       elif ($blockers | any(.kind == "checks" and (.text | test("failing"))))
       then turn_of("worker"; "the worker fixing failing checks";
                    "its checks are failing"; null)
       elif ($blockers | any(.kind == "draft"))
       then turn_of("worker"; "the worker finishing a draft"; "it is still a draft"; null)
       elif ($live.checks.state // "") == "pending"
       then turn_of("external"; "CI checks"; "its checks are still running"; null)
       elif ($task.current_state.state // "") == "working"
       # Only an attributed pipeline run is evidence that VALIDATION is what is
       # happening; a busy worker is evidence only that the worker is busy, and
       # the activity line below carries its own latest words either way.
       then (if ($task.current_state.source // "") == "run-step"
             then turn_of("worker"; "validation finishing";
                          "its pipeline is still running"; null)
             else turn_of("worker"; "the worker, still active on it";
                          "its lane is still working"; null) end)
       elif ($blockers | any(.kind == "checks"))
       then turn_of("external"; "confirmed check status";
                    "its checks have not reported"; null)
       elif ($blockers | any(.kind == "depends-on"))
       then turn_of("captain";
                    ("you to land " + ([$blockers[] | select(.kind == "depends-on")
                                        | .text | sub("^waits on "; "")] | join(", "))
                     + " first");
                    "it stacks on work that has not landed"; "merge")
       elif ($blockers | any(.kind == "hold"))
       then turn_of("captain"; "your call on the hold"; "it is held"; "decide")
       elif ($blockers | any(.kind == "worker"))
       then turn_of("worker"; "the worker recovering"; "its lane stopped"; null)
       else turn_of("captain"; "your merge"; "nothing else is blocking it"; "merge")
       end)
    + since_of(($brec.since | nn); $ref.id)
  ]
  # The captain's own turn first, then what someone else owes: the top of this
  # list is the next thing he can actually do.
  | sort_by([(if .turn == "captain" then 0 elif .turn == "external" then 1 else 2 end),
             (if .status == "ready" then 0 else 1 end), .number]) as $merge_queue

# ---- live lanes and their own activity feeds --------------------------------
| [ $tasks[]
    | select(.kind != "secondmate")
    | . as $t
    | (.current_state.state // "unknown") as $st
    | {
        id: .id,
        title: (($t.backlog.title | nn) // .id),
        project: (($t.backlog.repo | nn) // ($t.project | nn)),
        kind: (.kind // "ship"),
        mode: (.mode // null),
        state: $st,
        state_source: (.current_state.source // "none"),
        detail: (.current_state.detail | nn | clip(200)),
        # A lane whose worker is gone is history, not work under way. It stays
        # listed - dropping finished lanes would hide work - but it is counted
        # and ordered as quiet so "in flight" never overstates the fleet.
        live: ((.endpoint.exists == true) and ($st != "done")),
        needs_captain: ((($t.hints.open_decisions // []) | length > 0)
                        or ($st | IN("blocked","failed","parked"))),
        pr: (if .pr.url != null
             then {url: .pr.url,
                   number: ((.pr.url | capture("/(?<n>[0-9]+)$").n // "0") | tonumber)}
             else null end),
        feed: [ (.paths.status_log.events // [])[]
                | {state: .state, note: (.note | trim | clip(220)), raw: .raw} ]
      }
    + {activity: activity_of($t)}
    + attendance_of($t)
    + (if ((($t.hints.open_decisions // []) | length) > 0)
       then turn_of("captain"; "your decision"; "it asked you a question"; "decide")
       elif $st == "parked"
       then turn_of("captain"; "your decision at a gate"; "its run is parked"; "decide")
       elif $st == "blocked"
       then turn_of("captain"; "help getting unblocked"; "it reported a blocker"; "decide")
       elif $st == "paused"
       then turn_of("external"; "a declared external wait"; "it is standing by"; null)
       elif $st == "working"
       then turn_of("worker"; "the worker"; "it is working"; null)
       elif $st == "failed"
       then turn_of("worker"; "the worker recovering"; "it failed"; null)
       else turn_of("worker"; "cleanup"; "it has finished its work"; null)
       end)
    + since_of(($t.backlog.since | nn); $t.id)
    | . + {rank: (if (.live | not) then 5
                  elif .needs_captain then 0
                  elif .state == "working" then 1
                  elif .state == "paused" then 2
                  elif .state == "done" then 4
                  else 3 end)}
  ]
  | sort_by([.rank, .id]) | map(del(.rank)) as $in_flight

# ---- recently landed --------------------------------------------------------
| ([ ($backlog[] | select(.state == "done")
      | {id: .id, title: ((.title | nn) // .id),
         when: ((.completion.date | nn) // (.merged | nn) // (.done | nn) // (.reported | nn)),
         verb: ((.completion.verb | nn) // "done"),
         project: (.repo | nn),
         url: (.pr_url | nn), source: "main"}),
     (($s.secondmate_landed.records // [])[]
      | {id: .id, title: ((.title | nn) // .id),
         when: ((.completion.date | nn) // (.merged | nn) // (.done | nn)),
         verb: ((.completion.verb | nn) // "done"),
         project: (.repo | nn),
         url: (.pr_url | nn), source: (.home_id // "secondmate")})
   ] | sort_by([(.when // ""), .id]) | reverse) as $completed_all
| ($completed_all[0:$completed_max]) as $completed

# ---- what the captain would otherwise discover by clicking ------------------
| ([
    (if ($pr_data.present | not)
     then {kind: "pr-data",
           text: "Pull request checks have not been fetched; merge rows show local records only. Refresh with --refresh-prs."}
     elif $pr_data.stale
     then {kind: "pr-data",
           text: ("Pull request checks are " + (($pr_data.age_seconds / 60) | floor | tostring)
                  + " minutes old; treat check state as unconfirmed.")}
     else empty end),
    (if ($s.main_inventory.valid == false)
     then {kind: "inventory",
           text: ("Fleet inventory is incomplete: " + ($s.main_inventory.reason // "unknown"))}
     else empty end),
    (($s.secondmate_landed.unreadable // [])[]
     | {kind: "secondmate", text: ("Could not read landed work from " + .)}),
    (if (($completed_all | length) > ($completed | length))
     then {kind: "retention",
           text: ((($completed_all | length) - ($completed | length) | tostring)
                  + " older landed items are not shown.")}
     else empty end)
  ]) as $notices

| {
    schema: $schema,
    generated: $generated,
    generated_display: $display,
    fm_home: $home,
    refresh_seconds: $refresh,
    source: {
      fleet_snapshot: {schema: $s.schema, generated: $s.generated},
      pr_data: $pr_data
    },
    counts: {
      # The inbox size: everything that is the captain's turn, counted once per
      # item id, because one lane blocked on one question is one thing to do.
      inbox: ([ ($merge_queue[] | select(.turn == "captain") | .id),
                ($awaiting[] | select(.turn == "captain") | .id),
                ($in_flight[] | select(.turn == "captain") | .id) ]
              | unique | length),
      mine: ([ ($merge_queue[]), ($awaiting[]), ($in_flight[]) ]
             | map(select(.turn == "captain")) | length),
      worker_turn: ([ ($merge_queue[]), ($awaiting[]), ($in_flight[]) ]
                    | map(select(.turn == "worker")) | length),
      external_turn: ([ ($merge_queue[]), ($awaiting[]), ($in_flight[]) ]
                      | map(select(.turn == "external")) | length),
      merge_queue: ($merge_queue | length),
      awaiting_captain: ($awaiting | length),
      ui: ([$awaiting[] | select(.type == "ui")] | length),
      plan: ([$awaiting[] | select(.type == "plan")] | length),
      decision: ([$awaiting[] | select(.type == "decision")] | length),
      decisions: ([$awaiting[] | .decision_count] | add // 0),
      in_flight: ($in_flight | length),
      in_flight_live: ([$in_flight[] | select(.live)] | length),
      completed: ($completed | length),
      notices: ($notices | length)
    },
    merge_queue: $merge_queue,
    awaiting_captain: $awaiting,
    in_flight: $in_flight,
    completed: $completed,
    notices: $notices
  }
JQ
  printf '%s' "$prog"
}

# A work item whose backlog row has already been archived has no title left in
# fleet state, and its bare task id is a poor thing to show a captain. The
# artifact itself carries the better name - it is exactly what they will read at
# the top of the page when they open it - so borrow that when nothing else has a
# title. Bounded: only items still falling back to their own id, first heading
# only, first 8KB of the file only.
document_title() {  # <path>
  local path=$1 title=''
  [ -f "$path" ] || return 0
  case "$path" in
    *.html)
      title=$(head -c 8192 "$path" | tr '\n' ' ' \
        | sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/p' | head -1)
      ;;
    *.md)
      title=$(grep -m1 '^# ' "$path" 2>/dev/null | sed 's/^#[[:space:]]*//')
      ;;
  esac
  printf '%s' "$title" \
    | sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
          -e 's/&quot;/"/g' -e "s/&#39;/'/g" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

enrich_titles() {  # <state-json> - rewrite in place
  local pairs id link title patch=$TMPWORK/titles.json
  pairs=$(jq -r '.awaiting_captain[]
    | select(.title == .id and .link != null and (.link | startswith("file://")))
    | "\(.id)\t\(.link)"' "$1")
  [ -n "$pairs" ] || return 0
  printf '{}' > "$patch"
  while IFS=$'\t' read -r id link; do
    [ -n "$id" ] || continue
    title=$(document_title "${link#file://}")
    [ -n "$title" ] || continue
    jq --arg id "$id" --arg title "$title" '. + {($id): $title}' "$patch" > "$patch.tmp" \
      && mv "$patch.tmp" "$patch"
  done <<EOF
$pairs
EOF
  jq --slurpfile patch "$patch" '
    .awaiting_captain |= map(. + {title: ($patch[0][.id] // .title)})' "$1" > "$1.tmp" \
    && mv "$1.tmp" "$1"
}

# When an item's only evidence is a status event, the log's own last-modified
# time is when that event was recorded - the honest answer to "how long has this
# been sitting". Durable backlog dates are preferred where they exist; this is
# the fallback, and the document says which of the two it used.
# Backlog dates are plain calendar days, so their epochs are resolved here for
# the same reason status mtimes are: jq's own date parsing is an hour out under
# daylight time. The set is small - a handful of distinct days across a backlog.
date_epochs() {  # <snapshot> -> path to {"YYYY-MM-DD": epoch} JSON
  local snap=$1 out=$TMPWORK/dates.json d epoch
  printf '{}' > "$out"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    epoch=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null \
      || date -u -d "$d" +%s 2>/dev/null) || continue
    [ -n "$epoch" ] || continue
    jq --arg d "$d" --argjson e "$epoch" '. + {($d): $e}' "$out" > "$out.tmp" \
      && mv "$out.tmp" "$out"
  done <<EOF
$(jq -r '[ .backlog.records[]? | .since, .merged, .done, .reported ]
         | map(select(. != null and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))
         | unique | .[]' "$snap" 2>/dev/null)
EOF
  printf '%s' "$out"
}

status_mtimes() {  # -> path to {id: epoch} JSON
  local out=$TMPWORK/mtimes.json f id epoch
  printf '{}' > "$out"
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .status)
    epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
    [ -n "$epoch" ] || continue
    jq --arg id "$id" --argjson m "$epoch" '. + {($id): $m}' "$out" > "$out.tmp" \
      && mv "$out.tmp" "$out"
  done
  printf '%s' "$out"
}

build_state() {  # <snapshot> <prs> <artifacts> -> state document on stdout
  local snap=$1 prs=$2 artifacts=$3 generated display epoch fetched_epoch prog mtimes dates
  generated=$(now_utc)
  display=$(display_stamp "$generated")
  epoch=$(iso_to_epoch "$generated")
  [ -n "$epoch" ] || epoch=0
  # Parsed with the same converter as the generated stamp, so the age between
  # them is a difference of two comparable instants.
  fetched_epoch=$(iso_to_epoch "$(jq -r '.fetched // ""' "$prs")")
  [ -n "$fetched_epoch" ] || fetched_epoch=0
  mtimes=$(status_mtimes)
  dates=$(date_epochs "$snap")
  prog=$(write_projection_program)
  jq -n \
    --slurpfile snap "$snap" \
    --slurpfile prs "$prs" \
    --slurpfile artifacts "$artifacts" \
    --slurpfile mtimes "$mtimes" \
    --slurpfile dates "$dates" \
    --arg schema "$SCHEMA" \
    --arg generated "$generated" \
    --arg display "$display" \
    --arg home "$FM_HOME" \
    --argjson refresh "$REFRESH" \
    --argjson ttl "$PR_TTL" \
    --argjson completed_max "$COMPLETED_MAX" \
    --argjson now_epoch "$epoch" \
    --argjson fetched_epoch "$fetched_epoch" \
    -f "$prog"
}

# ---------------------------------------------------------------------------
# Rendering: fm-mission-control.v1 -> one self-contained offline page
#
# The renderer reads the state document and nothing else, so the page can never
# show a fact the document does not contain.
# ---------------------------------------------------------------------------

render_html() {  # <state-json>
  local state=$1 refresh body
  refresh=$(jq -r '.refresh_seconds // 60' "$state")
  # Render the body first: a half-written page that looks plausible is exactly
  # the dashboard-that-lies failure, so a render error must produce no page.
  body=$(jq -r -f "$(write_render_program)" "$state") || die "render failed"
  render_head "$refresh"
  printf '%s\n' "$body"
  render_tail "$state"
}

render_head() {  # <refresh-seconds>
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="$1">
<title>Mission control</title>
<style>
HTML
  render_css
  cat <<'HTML'
</style>
</head>
<body>
HTML
}

render_css() {
  cat <<'CSS'
  :root {
    color-scheme: light dark;
    --bg:#f6f5f1; --surface:#fffefb; --ink:#171714; --muted:#56554e; --faint:#7d7c74;
    --line:#dedcd3; --hair:#e9e7de;
    --go:#186238; --go-soft:#e6efe8; --warn:#7d500c; --warn-soft:#f6edda;
    --stop:#8a2b20; --stop-soft:#f8e6e3; --info:#1f5385; --info-soft:#e4edf6;
    --gap:.7rem; --pad:1rem;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg:#16161a; --surface:#1e1e23; --ink:#f0efea; --muted:#adaca2; --faint:#8a8980;
      --line:#35353d; --hair:#2b2b32;
      --go:#7fcb9b; --go-soft:#1c3025; --warn:#e0b46a; --warn-soft:#302718;
      --stop:#ec9689; --stop-soft:#37201c; --info:#8dbbe8; --info-soft:#1b2836;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    background: var(--bg); color: var(--ink); overflow: hidden;
    font: 15px/1.45 ui-sans-serif, -apple-system, "Segoe UI", system-ui, sans-serif;
    display: flex; flex-direction: column; -webkit-font-smoothing: antialiased;
  }
  a { color: inherit; }

  /* --- chrome: quieter than any content --- */
  .bar {
    flex: 0 0 auto; display: flex; align-items: center; gap: .9rem;
    padding: .55rem var(--pad); border-bottom: 1px solid var(--line);
  }
  .bar h1 { font-size: .875rem; font-weight: 700; letter-spacing: -.005em; }
  .bar .stamp { font-size: .8125rem; color: var(--faint); margin-left: auto; }
  .views { display: flex; gap: .15rem; }
  .views button {
    font: inherit; font-size: .8125rem; font-weight: 600; color: var(--muted);
    background: none; border: 0; border-radius: 6px; padding: .2rem .6rem;
    cursor: pointer; display: flex; align-items: center; gap: .35rem;
  }
  .views button:hover { color: var(--ink); background: var(--surface); }
  .views button.on { background: var(--surface); color: var(--ink); box-shadow: inset 0 0 0 1px var(--line); }
  .views .badge {
    font-size: .75rem; font-weight: 700; background: var(--go-soft); color: var(--go);
    border-radius: 9px; padding: 0 .35rem; min-width: 1.25rem; text-align: center;
  }

  /* --- banner: says what is wrong AND offers the way out --- */
  .banner {
    flex: 0 0 auto; display: flex; align-items: baseline; gap: .6rem; flex-wrap: wrap;
    padding: .5rem var(--pad); border-bottom: 1px solid var(--line);
    background: var(--warn-soft); color: var(--warn); font-size: .8125rem;
  }
  .banner .act {
    font: inherit; font-size: .78125rem; font-weight: 600; cursor: pointer;
    background: transparent; color: var(--warn); border: 1px solid currentColor;
    border-radius: 5px; padding: .1rem .5rem;
  }
  .banner code {
    font: inherit; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: .75rem; background: var(--surface); color: var(--ink);
    padding: .1rem .35rem; border-radius: 4px; user-select: all;
  }
  .banner code[hidden] { display: none; }

  main { flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column;
         gap: var(--gap); padding: var(--gap) var(--gap) var(--gap); }
  main[hidden] { display: none; }

  /* --- STAMP-S: the queue dominates; everything else is a secondary rail --- */
  .attention { flex: 2.1 1 0; min-height: 0; }
  .lower { flex: 1 1 0; min-height: 0; display: grid; gap: var(--gap);
           grid-template-columns: 1.45fr 1fr; }
  @media (max-width: 900px) { .lower { grid-template-columns: 1fr; } }

  .card { background: var(--surface); border-radius: 10px; min-height: 0;
          display: flex; flex-direction: column; overflow: hidden; }
  .card > h2 {
    flex: 0 0 auto; display: flex; align-items: baseline; gap: .5rem;
    padding: .6rem var(--pad) .45rem; font-size: .875rem; font-weight: 650;
    letter-spacing: -.005em; color: var(--ink);
  }
  .card > h2 .count { margin-left: auto; font-size: .8125rem; font-weight: 500; color: var(--muted); }
  .card > h2 .count b { font-weight: 650; color: var(--ink); }
  .scroll { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 0 var(--pad) .7rem; }
  .scroll::-webkit-scrollbar { width: 8px; }
  .scroll::-webkit-scrollbar-thumb { background: var(--line); border-radius: 4px; }

  /* --- the queue row: aligned columns, one obvious action --- */
  .item { border-top: 1px solid var(--hair); }
  .item:first-child { border-top: none; }
  .item > summary, .item > .line {
    display: grid; align-items: baseline; gap: .75rem;
    grid-template-columns: 5.75rem minmax(0, 1fr) minmax(0, 15rem) 5.5rem 5.25rem;
    padding: .7rem .35rem .75rem; cursor: pointer; list-style: none;
    border-radius: 7px;
  }
  .item > summary::-webkit-details-marker { display: none; }
  .item > summary:hover, .item > .line:hover { background: var(--bg); }
  .item > summary:focus-visible, .item > .line:focus-visible,
  .item.here > summary, .item.here > .line {
    background: var(--bg); outline: 2px solid var(--info); outline-offset: -2px;
  }
  .item .title { font-size: .9375rem; font-weight: 600; line-height: 1.35; }
  .item .title a { text-decoration: none; }
  .item .title a:hover { text-decoration: underline; text-underline-offset: 2px; }
  .item .why, .item .when { font-size: .8125rem; color: var(--muted); line-height: 1.45; }
  .item .when { text-align: right; font-variant-numeric: tabular-nums; }
  .item .go {
    justify-self: end; font-size: .8125rem; font-weight: 600; color: var(--go);
    border: 1px solid var(--go); border-radius: 6px; padding: .12rem .5rem;
    text-decoration: none; white-space: nowrap;
  }
  .item .go:hover { background: var(--go-soft); }
  .item[open] > summary { background: var(--bg); }
  .detail { padding: .1rem .35rem .8rem 6.5rem; }
  @media (max-width: 1100px) {
    .item > summary, .item > .line { grid-template-columns: 5.75rem minmax(0,1fr) 4.5rem 5.25rem; }
    .item .why { grid-column: 2 / -1; grid-row: 2; }
    .detail { padding-left: .35rem; }
  }

  /* --- STAMP-P: a word first, a tone second --- */
  .chip {
    justify-self: start; font-size: .75rem; font-weight: 650; letter-spacing: .01em;
    padding: .12rem .45rem .16rem; border-radius: 5px; white-space: nowrap;
    background: var(--info-soft); color: var(--info);
  }
  .chip.merge { background: var(--go-soft); color: var(--go); }
  .chip.decide { background: var(--warn-soft); color: var(--warn); }
  .chip.blocked { background: var(--stop-soft); color: var(--stop); }
  .chip.working { background: var(--bg); color: var(--muted); box-shadow: inset 0 0 0 1px var(--line); }
  .chip.done { background: transparent; color: var(--faint); box-shadow: inset 0 0 0 1px var(--line); }

  /* --- blocked is three states, never one amber chip --- */
  .att { font-size: .8125rem; line-height: 1.45; }
  .item .att { grid-column: 2 / -1; margin-top: .18rem; }
  .att .dot { display: inline-block; width: .45rem; height: .45rem; border-radius: 50%;
              margin-right: .35rem; vertical-align: .04em; background: currentColor; }
  .att.fixing { color: var(--muted); }
  .att.stalled { color: var(--stop); font-weight: 600; }
  .att.unverified { color: var(--warn); }

  /* --- decisions live inside their plan's row --- */
  .qs { list-style: none; }
  .qs li { padding: .3rem 0 .35rem; border-top: 1px solid var(--hair); }
  .qs li:first-child { border-top: none; }
  .qs .q { font-size: .875rem; color: var(--ink); line-height: 1.4; }
  .qs .rec, .qs .because {
    display: block; font-size: .8125rem; line-height: 1.45; margin-top: .15rem;
    padding-left: .6rem; border-left: 2px solid var(--go-soft); color: var(--muted);
  }
  .qs .rec { border-left-color: var(--go); color: var(--ink); }
  .next { font-size: .8125rem; color: var(--muted); line-height: 1.45; }

  /* --- active work: one row per workstream, timeline behind expansion --- */
  .lane { border-top: 1px solid var(--hair); }
  .lane:first-child { border-top: none; }
  .lane > summary {
    padding: .6rem .35rem .65rem; cursor: pointer; list-style: none; border-radius: 7px;
  }
  .lane > summary::-webkit-details-marker { display: none; }
  .lane > summary:hover { background: var(--bg); }
  .lane .name { font-size: .9375rem; font-weight: 600; line-height: 1.35; }
  .lane .sub { font-size: .8125rem; color: var(--muted); line-height: 1.45; margin-top: .12rem;
               display: flex; flex-wrap: wrap; gap: .4rem; align-items: baseline; }
  .lane.quiet .name { color: var(--muted); font-weight: 500; }
  .feed { list-style: none; padding: 0 .35rem .7rem 1rem; }
  .feed li { display: flex; gap: .6rem; align-items: baseline; padding: .18rem 0;
             font-size: .8125rem; color: var(--muted); line-height: 1.45; }
  .feed .v { flex: 0 0 5rem; color: var(--faint); font-weight: 600; text-align: right; }
  .feed .v.done { color: var(--go); }
  .feed .v.decision, .feed .v.paused { color: var(--warn); }
  .feed .v.blocked, .feed .v.failed { color: var(--stop); }

  /* --- landed --- */
  .landed { border-top: 1px solid var(--hair); padding: .5rem .35rem .55rem; }
  .landed:first-child { border-top: none; }
  .landed .t { font-size: .875rem; line-height: 1.4; }
  .landed .t a { text-decoration: none; }
  .landed .m { font-size: .8125rem; color: var(--muted); margin-top: .1rem; }
  .older > summary { cursor: pointer; list-style: none; font-size: .8125rem;
                     font-weight: 600; color: var(--info); padding: .5rem .35rem; }
  .older > summary::-webkit-details-marker { display: none; }

  .sep { color: var(--faint); }
  .empty { padding: 1.6rem .35rem; text-align: center; }
  .empty .big { font-size: 1.0625rem; font-weight: 650; color: var(--go); }
  .empty .small { font-size: .875rem; color: var(--muted); margin-top: .25rem; }
  .hint { font-size: .78125rem; color: var(--faint); padding: .45rem .35rem 0; }

  /* --- inbox --- */
  .filters { flex: 0 0 auto; display: flex; flex-wrap: wrap; align-items: center;
             gap: .5rem 1.1rem; padding: 0 var(--pad) .55rem; }
  .fset { display: flex; align-items: center; gap: .4rem; }
  .fset > .lab { font-size: .78125rem; color: var(--faint); font-weight: 600; }
  .fgroup { display: flex; gap: .15rem; background: var(--bg); border-radius: 7px; padding: .15rem; }
  .fgroup button {
    font: inherit; font-size: .8125rem; font-weight: 600; color: var(--muted);
    background: none; border: 0; border-radius: 5px; padding: .18rem .55rem; cursor: pointer;
  }
  .fgroup button:hover { color: var(--ink); }
  .fgroup button.on { background: var(--surface); color: var(--ink);
                      box-shadow: inset 0 0 0 1px var(--line); }
  .fgroup button .n { color: var(--faint); font-weight: 500; margin-left: .25rem; }
  .fgroup button.on .n { color: var(--muted); }
  .filters .shown { margin-left: auto; font-size: .8125rem; color: var(--faint); }
  .group-head { font-size: .78125rem; font-weight: 650; color: var(--muted);
                padding: .8rem .35rem .3rem; }
  .group-head:first-child { padding-top: .2rem; }

  @media (max-width: 760px), (max-height: 560px) {
    body { overflow: auto; }
    main { height: auto; }
    .attention, .lower { flex: none; }
    .card { min-height: 12rem; }
  }
CSS
}

write_render_program() {  # -> path to the jq render program
  local prog=$TMPWORK/render.jq
  cat > "$prog" <<'JQ'
def e: (. // "") | tostring | @html;
def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
def clip($n):
  if . == null then null
  elif (. | length) <= $n then .
  else (.[0:$n] | sub("[[:space:]][^[:space:]]*$"; "")) + "…" end;

# Null-tolerant on purpose: one odd record must never blank the whole page.
def shorten($t; $projects; $n):
  (($t // "") | tostring) as $t
  | ([ $projects[]? | select(. != null) | split("/") | last | norm ]) as $ps
  | (if ($t | test("^[^:]{1,40}:"))
        and (($t | split(":")[0] | norm) as $h | $ps | index($h)) != null
     then ($t | sub("^[^:]*:[[:space:]]*"; ""))
     else $t end)
  | clip($n);

def readable:
  (. // "")
  | gsub("https?://[^[:space:],;)\\]\"'<>]*/(pull|merge_requests)/(?<n>[0-9]+)"; "#\(.n)")
  | gsub("https?://[^[:space:],;)\\]\"'<>]+"; "a link")
  | gsub("(file://)?[^[:space:],;)\\]\"'<>]*/(?<file>[^[:space:]/,;)\\]\"'<>]+\\.[A-Za-z0-9]{1,6})";
        "\(.file)")
  | sub("^[[:space:]]+"; "");

# Human elapsed time. The captain reads "2d", not an ISO date.
def ago($s):
  if $s == null then "-"
  elif $s < 90 then "just now"
  elif $s < 3600 then "\(($s / 60) | floor)m"
  elif $s < 86400 then "\(($s / 3600) | floor)h"
  elif $s < 172800 then "yesterday"
  else "\(($s / 86400) | floor)d" end;

# Every link the captain follows from the queue opens in a new tab: he works
# from this page and must not lose it.
def link($href; $text):
  if $href == null then ($text | e)
  else "<a href=\"\($href | @uri | gsub("%3A"; ":") | gsub("%2F"; "/"))\" target=\"_blank\" rel=\"noopener\">\($text | e)</a>"
  end;

def action_word:
  if . == "merge" then "Merge" elif . == "look" then "Review"
  elif . == "read" then "Review" elif . == "decide" then "Decide"
  else "Waiting" end;
def action_class:
  if . == "merge" then "merge" elif . == "decide" then "decide"
  elif . == null then "working" else "" end;

# Blocked is three states, and the unattended one must be said outright.
def attention_line:
  if .attended == true
  then "<div class=\"att fixing\"><span class=\"dot\"></span>Being worked on now"
       + "<span class=\"sep\"> · </span>\(.activity.text | readable | clip(90) | e)</div>"
  elif .attended == false
  then "<div class=\"att stalled\"><span class=\"dot\"></span>Nobody is working on this"
       + (if .age_seconds != null then " · unattended \(ago(.age_seconds))" else "" end)
       + "</div>"
  else "<div class=\"att unverified\"><span class=\"dot\"></span>Ownership unverified"
       + "<span class=\"sep\"> · </span>could not confirm whether anyone is on it</div>"
  end;

def why_now($fetched):
  if .row == "pr"
  then (if .turn == "captain" and .action != "merge"
        then (.waiting_for | e)
        elif .turn == "captain"
        then (if ($fetched | not) then "checks not fetched"
              elif .checks.state == "passing" then "checks passing"
              elif .checks.state == "none" then "no checks"
              else "checks \(.checks.state)" end)
        else (.waiting_for | e) end)
  elif (.decision_count // 0) > 0
  then "\(.decision_count) question\(if .decision_count == 1 then "" else "s" end)"
       + (if (.recommended_count // 0) > 0 then " · \(.recommended_count) recommended" else "" end)
  else (.waiting_for | e) end;

def type_label:
  if .row == "pr" then "PR" elif .row == "ui" then "UI"
  elif .row == "plan" then "Plan" elif .row == "decision" then "Decision"
  else "Lane" end;

# The questions inside a plan, shown only when the row is opened: the dashboard
# summarises state, it does not reproduce everything at rest.
def questions_block:
  "<div class=\"detail\"><ul class=\"qs\">"
  + ([ .decisions[]
       | "<li><span class=\"q\">\(.question | readable | clip(180) | e)</span>"
         + (if .recommendation != null
            then "<span class=\"rec\">Recommended: \(.recommendation | readable | clip(220) | e)</span>"
            elif .reasoning != null
            then "<span class=\"because\">\(.reasoning | readable | clip(220) | e)</span>"
            else "" end)
         + "</li>" ] | join(""))
  + "</ul></div>";

# One row per item. A plan carrying decisions is ONE row - the plan - with its
# questions folded in behind expansion, never duplicated as separate decision
# rows.
def queue_row($names; $fetched):
  . as $it
  | (if (.decisions | length) > 0 then "details" else "div" end) as $tag
  | (if $tag == "details" then "summary" else "div" end) as $inner
  | "<\($tag) class=\"item\" data-item-id=\"\(.id | e)\" data-open-key=\"item.\(.id | e)\" data-turn=\"\(.turn)\" data-kind=\"\(.row)\" data-age=\"\(.age_seconds // 0)\" data-priority=\"\(if (.stuck // false) then 0 else 1 end)\">"
  + "<\($inner) class=\"\(if $inner == "div" then "line" else "" end)\" tabindex=\"0\">"
  + "<span class=\"chip \(.action | action_class)\">\(.action | action_word)</span>"
  + "<span class=\"title\">\(link(.link // .url; (if .row == "pr" then "#\(.number) " else "" end) + shorten(.title; $names + [.project, .repo]; 92)))</span>"
  + "<span class=\"why\">\(why_now($fetched))</span>"
  + "<span class=\"when\">\(ago(.age_seconds))</span>"
  + (if .link != null or .url != null
     then "<a class=\"go\" href=\"\((.link // .url) | @uri | gsub("%3A"; ":") | gsub("%2F"; "/"))\" target=\"_blank\" rel=\"noopener\">\(.action | action_word) →</a>"
     else "<span></span>" end)
  # Blocked work is where "is anyone on it?" decides whether the captain steps
  # in, so it is answered on the row itself rather than behind expansion. A PR
  # that is simply his to merge needs no such line.
  + (if (.stuck // false) or ((.state // "") | IN("blocked", "failed")) or .turn != "captain"
     then attention_line else "" end)
  + "</\($inner)>"
  + (if $tag == "details" then questions_block else "" end)
  + "</\($tag)>";

def lane_row($names):
  "<details class=\"lane\(if .live then "" else " quiet" end)\" data-lane=\"\(.id)\" data-open-key=\"lane.\(.id | e)\">"
  + "<summary tabindex=\"0\"><div class=\"name\">\(shorten(.title; $names + [.project]; 74) | e)</div>"
  + "<div class=\"sub\">"
  # The vocabulary the captain reads is Blocked / Working / Waiting / Complete.
  # Raw lane states like `unknown` are internal and never surface here.
  + (if .state == "blocked" or .state == "failed" then "<span class=\"chip blocked\">Blocked</span>"
     elif .turn == "captain" then "<span class=\"chip decide\">Needs you</span>"
     elif .state == "working" then "<span class=\"chip working\">Working</span>"
     elif .state == "paused" then "<span class=\"chip working\">Waiting</span>"
     elif .live then "<span class=\"chip working\">Working</span>"
     else "<span class=\"chip done\">Complete</span>" end)
  + "<span>\(.activity.text | readable | clip(80) | e)</span>"
  + "<span class=\"sep\">·</span><span>\(ago(.age_seconds))</span>"
  + "</div>"
  + (if .state == "blocked" or .turn == "captain" then attention_line else "" end)
  + "</summary>"
  + (if (.feed | length) == 0 then "<div class=\"hint\">No activity recorded yet.</div>"
     else "<ul class=\"feed\">"
          + ([ .feed[] | "<li><span class=\"v \(.state | e)\">\(if .state == "needs-decision" then "decision" else .state end | e)</span>"
               + "<span>\(.note | readable | clip(150) | e)</span></li>" ] | join(""))
          + "</ul>" end)
  + "</details>";

def landed_row($names):
  "<div class=\"landed\"><div class=\"t\">\(link(.url; shorten(.title; $names + [.project]; 84)))</div>"
  + "<div class=\"m\">\(.verb | e)\(if .when != null then " \(.when | e)" else "" end)"
  + (if .source != "main" then "<span class=\"sep\"> · </span>\(.source | e)" else "" end)
  + "</div></div>";

. as $d
| ([ $d.awaiting_captain[].project, $d.merge_queue[].repo,
     $d.in_flight[].project, $d.completed[].project ]
   | map(select(. != null)) | unique) as $names
| ($d.source.pr_data.present) as $fetched
| ([ (.merge_queue[] | . + {row: "pr"}),
     (.awaiting_captain[] | . + {row: .type}),
     (.in_flight[] | . + {row: "lane", decisions: [], decision_count: 0}) ]
   # One lane blocked on one question is one thing to do: the specific ask wins
   # over the pull request or lane waiting on it.
   | group_by(.id)
   | map(sort_by(if .row == "pr" then 1 elif .row == "lane" then 2 else 0 end) | .[0])
   # Whose turn first, then work that is actually stuck, then age. Blocked work
   # outranks merely old work, which is what "sort by blocked, then age" means.
   | sort_by([(if .turn == "captain" then 0 elif .turn == "external" then 1 else 2 end),
              (if (.stuck // false) then 0 else 1 end),
              (0 - (.age_seconds // 0))])) as $all
| ([ $all[] | select(.turn == "captain") ]) as $mine
| ([ $d.in_flight[] | select(.turn != "captain") ]) as $lanes

| "<header class=\"bar\"><h1>Mission control</h1>"
  + "<nav class=\"views\">"
  + "<button type=\"button\" data-view=\"panels\" class=\"on\">Board</button>"
  + "<button type=\"button\" data-view=\"inbox\">Inbox<span class=\"badge\" id=\"inbox-count\">\($mine | length)</span></button>"
  + "</nav>"
  + "<p class=\"stamp\" title=\"Regenerated by fm-dashboard.sh; the page reloads itself every \($d.refresh_seconds)s\">"
  + "updated \($d.generated_display | e)<span class=\"sep\"> · </span><span id=\"next\"></span></p></header>"

+ (if ($d.notices | length) > 0
   then "<div class=\"banner\">"
        + ([ $d.notices[]
             | if .kind == "pr-data"
               then "<span>Pull request checks are not current. Merge readiness may be outdated.</span>"
                    + "<button type=\"button\" class=\"act\" data-reveal=\"refresh-cmd\">Refresh checks</button>"
                    + "<code id=\"refresh-cmd\" hidden>bin/fm-dashboard.sh --refresh-prs</code>"
               else "<span>\(.text | e)</span>" end ] | join(""))
        + "</div>"
   else "" end)

+ "<main id=\"view-panels\">"
+ "<section class=\"card attention\"><h2>Needs your attention"
  + "<span class=\"count\"><b>\($mine | length)</b> item\(if ($mine | length) == 1 then "" else "s" end)</span></h2>"
  + "<div class=\"scroll\" data-scroll=\"attention\" id=\"queue\">"
  + (if ($mine | length) == 0
     then "<div class=\"empty\"><div class=\"big\">All caught up</div>"
          + "<div class=\"small\">Nothing is waiting on you. \($lanes | length) workstream\(if ($lanes | length) == 1 then " is" else "s are" end) still running.</div></div>"
     else ([ $mine[] | queue_row($names; $fetched) ] | join("")) end)
  + "</div></section>"

+ "<div class=\"lower\">"
+ "<section class=\"card\"><h2>Active work"
  # Only work that is actually stuck earns an alarm count. Calling every quiet
  # finished lane "unattended" would cry wolf, which is the same failure as
  # staying silent about the one that really is stalled.
  + "<span class=\"count\">"
  + (([ $lanes[] | select(.attended == false and (.state | IN("blocked", "failed"))) ] | length) as $stuck
     | if $stuck > 0 then "<b>\($stuck)</b> stuck<span class=\"sep\"> · </span>" else "" end)
  + "\([ $lanes[] | select(.live) ] | length) running</span></h2>"
  + "<div class=\"scroll\" data-scroll=\"lanes\">"
  + (if ($lanes | length) == 0 then "<div class=\"hint\">No workstreams running.</div>"
     else ([ $lanes[] | lane_row($names) ] | join("")) end)
  + "</div></section>"
+ "<section class=\"card\"><h2>Recently landed"
  + "<span class=\"count\">\($d.completed | length)</span></h2>"
  + "<div class=\"scroll\" data-scroll=\"landed\">"
  + (if ($d.completed | length) == 0 then "<div class=\"hint\">Nothing landed yet.</div>"
     else ([ $d.completed[0:6][] | landed_row($names) ] | join(""))
          + (if ($d.completed | length) > 6
             then "<details class=\"older\" data-open-key=\"older\"><summary>View \(($d.completed | length) - 6) older</summary>"
                  + ([ $d.completed[6:][] | landed_row($names) ] | join(""))
                  + "</details>"
             else "" end) end)
  + "</div></section>"
+ "</div></main>"

+ "<main id=\"view-inbox\" hidden><section class=\"card\">"
  + "<h2>Inbox<span class=\"count\" id=\"inbox-shown\"></span></h2>"
  + "<div class=\"filters\">"
  + "<div class=\"fset\"><span class=\"lab\">Whose turn</span><div class=\"fgroup\" data-filter=\"turn\">"
  + ([ {v: "captain", l: "Mine"}, {v: "external", l: "External"},
       {v: "worker", l: "Worker"}, {v: "all", l: "Everything"} ]
     | map(. as $f
       | ($all | map(select($f.v == "all" or .turn == $f.v)) | length) as $n
       | "<button type=\"button\" data-turn=\"\($f.v)\"\(if $f.v == "captain" then " class=\"on\"" else "" end)>\($f.l)<span class=\"n\">\($n)</span></button>")
     | join(""))
  + "</div></div>"
  + "<div class=\"fset\"><span class=\"lab\">Type</span><div class=\"fgroup\" data-filter=\"kind\">"
  + ([ {v: "all", l: "All"}, {v: "pr", l: "PRs"}, {v: "ui", l: "UI"},
       {v: "plan", l: "Plans"}, {v: "decision", l: "Decisions"}, {v: "lane", l: "Lanes"} ]
     | map(. as $f
       | ($all | map(select($f.v == "all" or .row == $f.v)) | length) as $n
       | "<button type=\"button\" data-kind=\"\($f.v)\"\(if $f.v == "all" then " class=\"on\"" else "" end)>\($f.l)<span class=\"n\">\($n)</span></button>")
     | join(""))
  + "</div></div>"
  + "<div class=\"fset\"><span class=\"lab\">Sort</span><div class=\"fgroup\" data-filter=\"sort\">"
  + ([ {v: "priority", l: "Priority"}, {v: "oldest", l: "Oldest"}, {v: "recent", l: "Recently updated"} ]
     | map("<button type=\"button\" data-sort=\"\(.v)\"\(if .v == "priority" then " class=\"on\"" else "" end)>\(.l)</button>")
     | join(""))
  + "</div></div>"
  + "</div>"
  + "<div class=\"scroll\" data-scroll=\"inbox\" id=\"inbox-list\">"
  + "<div class=\"group-head\" data-group=\"captain\">Needs action</div>"
  + ([ $all[] | select(.turn == "captain") | queue_row($names; $fetched) ] | join(""))
  + "<div class=\"group-head\" data-group=\"other\">For awareness</div>"
  + ([ $all[] | select(.turn != "captain") | queue_row($names; $fetched) ] | join(""))
  + "<div class=\"empty\" id=\"inbox-empty\" hidden><div class=\"big\">Nothing here</div>"
  + "<div class=\"small\">Pick another filter.</div></div>"
  + "</div></section></main>"
JQ
  printf '%s' "$prog"
}
render_tail() {  # <state-json>
  printf '<script type="application/json" id="mission-control-state">\n'
  # The embedded copy is the exact document this page renders. `<` is escaped so
  # a status note containing markup can never close this script element early.
  jq -c '.' "$1" | sed 's/</\\u003c/g'
  printf '\n</script>\n'
  cat <<'HTML'
<script>
// Offline, self-contained behaviour only - no network, no framework.
//
// The page reloads itself on a <meta refresh> because a file:// page cannot
// fetch its own data: Chrome blocks fetch and XMLHttpRequest from a file://
// origin. The page never scrolls, but its regions do, so scroll offsets, the
// chosen view, the filters and every expanded row are carried across that
// reload rather than being silently reset.
(function () {
  var store = null;
  try { store = window.sessionStorage; } catch (e) { store = null; }
  var save = function (k, v) { try { if (store) store.setItem('mc.' + k, v); } catch (e) {} };
  var load = function (k, d) {
    try { return (store && store.getItem('mc.' + k)) || d; } catch (e) { return d; }
  };

  document.querySelectorAll('[data-scroll]').forEach(function (el) {
    var key = 'scroll.' + el.getAttribute('data-scroll');
    var saved = parseInt(load(key, '0'), 10);
    if (saved > 0) { el.scrollTop = saved; }
    el.addEventListener('scroll', function () { save(key, String(el.scrollTop)); }, { passive: true });
  });

  // Expanded rows are the captain's own progressive-disclosure choices; keep them.
  document.querySelectorAll('details[data-open-key]').forEach(function (d) {
    var key = 'open.' + d.getAttribute('data-open-key');
    if (load(key, '') === '1') { d.open = true; }
    d.addEventListener('toggle', function () { save(key, d.open ? '1' : '0'); });
  });

  var views = { panels: document.getElementById('view-panels'),
                inbox: document.getElementById('view-inbox') };
  var showView = function (name) {
    if (!views[name]) { name = 'panels'; }
    Object.keys(views).forEach(function (k) { if (views[k]) views[k].hidden = (k !== name); });
    document.querySelectorAll('.views button').forEach(function (b) {
      b.classList.toggle('on', b.getAttribute('data-view') === name);
    });
    save('view', name);
    setCursor(-1);
  };
  document.querySelectorAll('.views button').forEach(function (b) {
    b.addEventListener('click', function () { showView(b.getAttribute('data-view')); });
  });

  // --- inbox filters and sort ---
  var filters = { turn: load('filter.turn', 'captain'),
                  kind: load('filter.kind', 'all'),
                  sort: load('filter.sort', 'priority') };
  var list = document.getElementById('inbox-list');
  var shown = document.getElementById('inbox-shown');
  var emptyNote = document.getElementById('inbox-empty');

  var applySort = function () {
    if (!list) { return; }
    ['captain', 'other'].forEach(function (group) {
      var head = list.querySelector('[data-group="' + group + '"]');
      if (!head) { return; }
      var rows = [], n = head.nextElementSibling;
      while (n && !n.classList.contains('group-head') && n.id !== 'inbox-empty') {
        rows.push(n); n = n.nextElementSibling;
      }
      rows.sort(function (a, b) {
        var aa = parseInt(a.getAttribute('data-age') || '0', 10);
        var bb = parseInt(b.getAttribute('data-age') || '0', 10);
        if (filters.sort === 'oldest') { return bb - aa; }
        if (filters.sort === 'recent') { return aa - bb; }
        var ap = parseInt(a.getAttribute('data-priority') || '1', 10);
        var bp = parseInt(b.getAttribute('data-priority') || '1', 10);
        if (ap !== bp) { return ap - bp; }
        return bb - aa;
      });
      rows.forEach(function (r) { head.parentNode.insertBefore(r, n); });
    });
  };

  var applyFilters = function () {
    if (!list) { return; }
    var visible = 0, total = 0;
    list.querySelectorAll('.item').forEach(function (el) {
      total += 1;
      var ok = (filters.turn === 'all' || el.getAttribute('data-turn') === filters.turn)
            && (filters.kind === 'all' || el.getAttribute('data-kind') === filters.kind);
      el.hidden = !ok;
      if (ok) { visible += 1; }
    });
    // A group heading with nothing under it is noise.
    list.querySelectorAll('.group-head').forEach(function (h) {
      var any = false, n = h.nextElementSibling;
      while (n && !n.classList.contains('group-head') && n.id !== 'inbox-empty') {
        if (n.classList.contains('item') && !n.hidden) { any = true; }
        n = n.nextElementSibling;
      }
      h.hidden = !any;
    });
    if (shown) { shown.textContent = visible + ' of ' + total; }
    if (emptyNote) { emptyNote.hidden = visible !== 0; }
    document.querySelectorAll('.fgroup button').forEach(function (b) {
      var g = b.parentNode.getAttribute('data-filter');
      b.classList.toggle('on', b.getAttribute('data-' + g) === filters[g]);
    });
    setCursor(-1);
  };

  document.querySelectorAll('.fgroup button').forEach(function (b) {
    b.addEventListener('click', function () {
      var g = b.parentNode.getAttribute('data-filter');
      filters[g] = b.getAttribute('data-' + g);
      save('filter.' + g, filters[g]);
      if (g === 'sort') { applySort(); }
      applyFilters();
    });
  });

  // --- j/k between items, Enter to open ---
  var cursor = -1;
  var rows = function () {
    var view = views.inbox && !views.inbox.hidden ? views.inbox : views.panels;
    if (!view) { return []; }
    return Array.prototype.filter.call(view.querySelectorAll('.item'), function (el) {
      return !el.hidden;
    });
  };
  function setCursor(i) {
    document.querySelectorAll('.item.here').forEach(function (el) { el.classList.remove('here'); });
    var all = rows();
    if (i < 0 || i >= all.length) { cursor = -1; return; }
    cursor = i;
    all[i].classList.add('here');
    all[i].scrollIntoView({ block: 'nearest' });
  }
  document.addEventListener('keydown', function (ev) {
    var tag = (ev.target && ev.target.tagName) || '';
    if (ev.metaKey || ev.ctrlKey || ev.altKey || tag === 'INPUT' || tag === 'TEXTAREA') { return; }
    var all = rows();
    if (ev.key === 'j') { ev.preventDefault(); setCursor(Math.min(cursor + 1, all.length - 1)); }
    else if (ev.key === 'k') { ev.preventDefault(); setCursor(Math.max(cursor - 1, 0)); }
    else if (ev.key === 'Enter' && cursor >= 0 && all[cursor]) {
      var a = all[cursor].querySelector('a.go') || all[cursor].querySelector('a');
      if (a) { ev.preventDefault(); window.open(a.href, '_blank', 'noopener'); }
    }
  });

  // The banner offers the way out; an offline page cannot run it, so it reveals
  // the exact command instead of pretending to have acted.
  document.querySelectorAll('[data-reveal]').forEach(function (b) {
    b.addEventListener('click', function () {
      var code = document.getElementById(b.getAttribute('data-reveal'));
      if (!code) { return; }
      code.hidden = !code.hidden;
      if (!code.hidden) {
        var r = document.createRange();
        r.selectNodeContents(code);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(r);
      }
    });
  });

  applySort();
  applyFilters();
  showView(load('view', 'panels'));

  // A visible countdown, so a page that looks static is provably still live.
  var meta = document.querySelector('meta[http-equiv="refresh"]');
  var next = document.getElementById('next');
  var left = meta ? parseInt(meta.getAttribute('content') || '0', 10) : 0;
  if (next && left > 0) {
    var tick = function () {
      next.textContent = left > 0 ? 'next check in ' + left + 's' : 'refreshing';
      left -= 1;
    };
    tick();
    setInterval(tick, 1000);
  }
})();
</script>
</body>
</html>
HTML
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

generate_once() {  # -> state document path
  local snap prs artifacts state=$TMPWORK/state.json
  snap=$(capture_snapshot)
  [ "$REFRESH_PRS" -eq 1 ] && refresh_pr_cache "$snap"
  prs=$(pr_cache_json)
  artifacts=$(artifact_index)
  build_state "$snap" "$prs" "$artifacts" > "$state" || die "projection failed"
  enrich_titles "$state"
  printf '%s' "$state"
}

write_outputs() {  # <state-json>
  local state=$1
  mkdir -p "$OUT_DIR"
  cp "$state" "$OUT_DIR/.mission-control.json.tmp" \
    && mv "$OUT_DIR/.mission-control.json.tmp" "$OUT_DIR/mission-control.json"
  render_html "$state" > "$OUT_DIR/.mission-control.html.tmp" \
    && mv "$OUT_DIR/.mission-control.html.tmp" "$OUT_DIR/mission-control.html"
}

case "$MODE" in
  render)
    [ -f "$RENDER_FROM" ] || die "state document not found: $RENDER_FROM"
    jq -e '.schema == "'"$SCHEMA"'"' "$RENDER_FROM" >/dev/null 2>&1 \
      || die "not a $SCHEMA document: $RENDER_FROM"
    render_html "$RENDER_FROM"
    exit 0
    ;;
  json)
    cat "$(generate_once)"
    exit 0
    ;;
esac

if [ "$WATCH" -eq 1 ]; then
  while :; do
    write_outputs "$(generate_once)"
    printf '%s  updated %s\n' "$(display_stamp "$(now_utc)")" "$OUT_DIR/mission-control.html"
    sleep "$WATCH_SECS"
  done
fi

write_outputs "$(generate_once)"
printf 'wrote %s\n' "$OUT_DIR/mission-control.json"
printf 'wrote %s\n' "$OUT_DIR/mission-control.html"
printf 'open  file://%s\n' "$OUT_DIR/mission-control.html"
