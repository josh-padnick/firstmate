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
#   FM_DASHBOARD_COMPLETED    completed rows to keep (8)
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
#   counts: {merge_queue, awaiting_captain, ui, plan, decision, decisions,
#            in_flight, completed, notices},
#
#   merge_queue[]: one open pull request the captain could land.
#     {id, title, url, number, repo, project, status: ready|held,
#      checks: {state: passing|failing|pending|none|unknown, summary, source},
#      blockers[]: {kind: checks|decision|worker|depends-on|hold|draft, text},
#      source: task-meta|backlog}
#     status is `held` exactly when blockers is non-empty, so "what blocks it"
#     is never a colour the captain has to interpret.
#
#   awaiting_captain[]: one artifact or question waiting on the captain, TYPED,
#     because reading a plan, looking at a UI, and answering a question are
#     different work.
#     {id, type: ui|plan|decision, kind, title, note, link,
#      link_kind: file|http|null, project, since,
#      source: status-decision|backlog-hold|scout-report,
#      decisions[]: {id, key, question}, decision_count, evidence}
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
#     {id, title, project, kind, mode, state, state_source, detail,
#      needs_captain, pr: {url, number}|null,
#      activity[]: {state, note, raw} newest first}
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
COMPLETED_MAX=${FM_DASHBOARD_COMPLETED:-8}

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

# Parsed with jq, not date(1): BSD date's `-j -f` applies local daylight rules to
# an input it was told is UTC, which puts the captain's stamp an hour out. jq is
# already required here and its fromdateiso8601 is correct on every platform.
iso_to_epoch() {  # <iso8601-utc> -> epoch seconds, or empty
  [ -n "${1:-}" ] || return 0
  jq -rn --arg s "$1" '($s | fromdateiso8601? // empty)' 2>/dev/null || true
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

$snap[0] as $s
| $prs[0] as $prcache
| $artifacts[0] as $index
| ($s.backlog.records // []) as $backlog
| ($s.tasks // []) as $tasks
| ($prcache.records // []) as $prrecords

# ---- PR data freshness ------------------------------------------------------
| (if $prcache.fetched == null then null
   else ($now_epoch - ($prcache.fetched | fromdateiso8601? // $now_epoch)) end) as $pr_age
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
     | {origin: $origin, key: $key, id: $r.id,
        question: (($r.title | nn) // ($r.hold_reason | nn) // $r.id),
        context: ($r.hold_reason | nn),
        since: ($r.since | nn),
        repo: ($r.repo | nn)}
   ]) as $held

# ---- decisions a worker still has open in its own status stream -------------
| ([ $tasks[]
     | . as $t
     | (.hints.open_decisions // [])[]
     | {origin: $t.id, key: .key, id: ($t.id + ":" + .key),
        question: (.summary | trim | clip(240)),
        context: null, since: null, repo: ($t.backlog.repo | nn)}
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
        since: (($ds | map(.since) | map(select(. != null)) | first)
                // ($brec.since | nn) // null),
        source: (if ($ds | any(.context != null or (.id | test(":") | not)))
                 then "backlog-hold" else "status-decision" end),
        decisions: [ $ds[] | {id: .id, key: .key, question: .question} ],
        decision_count: ($ds | length),
        evidence: (($task.hints.last_event_text | nn) // ($brec.raw | nn) // null)
      }
  ] as $decision_items

# ---- finished work whose deliverable is a document nobody has read yet ------
| [ $tasks[]
    | select(.kind != "secondmate")
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
        since: ($t.backlog.since | nn),
        source: "scout-report",
        decisions: [],
        decision_count: 0,
        evidence: ($t.hints.last_event_text | nn)
      }
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
        (if ($live.draft // false) then {kind: "draft", text: "still a draft"}
         else empty end),
        (if ($task.current_state.state // "") | IN("blocked","failed")
         then {kind: "worker",
               text: (($task.current_state.detail | nn | clip(160))
                      // ("the lane is " + $task.current_state.state))}
         else empty end),
        ($task.hints.open_decisions // [] | .[]
         | {kind: "decision", text: ("waiting on your decision: "
                                     + (.summary | trim | clip(160)))}),
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
  ]
  | sort_by([(if .status == "ready" then 0 else 1 end), .number]) as $merge_queue

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
        activity: [ (.paths.status_log.events // [])[]
                    | {state: .state, note: (.note | trim | clip(220)), raw: .raw} ]
      }
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
      | {id: .id, title: (.title | nn // .id),
         when: ((.completion.date | nn) // (.merged | nn) // (.done | nn) // (.reported | nn)),
         verb: ((.completion.verb | nn) // "done"),
         project: (.repo | nn),
         url: (.pr_url | nn), source: "main"}),
     (($s.secondmate_landed.records // [])[]
      | {id: .id, title: (.title | nn // .id),
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

build_state() {  # <snapshot> <prs> <artifacts> -> state document on stdout
  local snap=$1 prs=$2 artifacts=$3 generated display epoch prog
  generated=$(now_utc)
  display=$(display_stamp "$generated")
  epoch=$(iso_to_epoch "$generated")
  [ -n "$epoch" ] || epoch=0
  prog=$(write_projection_program)
  jq -n \
    --slurpfile snap "$snap" \
    --slurpfile prs "$prs" \
    --slurpfile artifacts "$artifacts" \
    --arg schema "$SCHEMA" \
    --arg generated "$generated" \
    --arg display "$display" \
    --arg home "$FM_HOME" \
    --argjson refresh "$REFRESH" \
    --argjson ttl "$PR_TTL" \
    --argjson completed_max "$COMPLETED_MAX" \
    --argjson now_epoch "$epoch" \
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
    --bg:#f6f5f1; --surface:#fffefb; --ink:#1a1a17; --muted:#6b6a63; --faint:#96958c;
    --line:#e2e0d8; --hair:#eceae2;
    --go:#1f6b3f; --go-soft:#e8f0e9; --warn:#8a5a12; --warn-soft:#f6efe1;
    --stop:#8f2f24; --stop-soft:#f7e8e6; --info:#2b5b8a; --info-soft:#e7eef6;
    --gap:.55rem; --pad:.8rem;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg:#16161a; --surface:#1e1e23; --ink:#ecebe6; --muted:#9a998f; --faint:#77766e;
      --line:#33333a; --hair:#2a2a31;
      --go:#6fbf8b; --go-soft:#1d2f24; --warn:#d6a95c; --warn-soft:#2e2617;
      --stop:#e08a7d; --stop-soft:#331e1b; --info:#7fb0e0; --info-soft:#1a2632;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    background: var(--bg); color: var(--ink); overflow: hidden;
    font: 15px/1.5 ui-sans-serif, -apple-system, "Segoe UI", system-ui, sans-serif;
    display: flex; flex-direction: column;
    -webkit-font-smoothing: antialiased;
  }

  /* --- top bar: chrome, deliberately quieter than any panel heading --- */
  .bar {
    flex: 0 0 auto; display: flex; align-items: baseline; gap: .75rem;
    padding: .5rem .9rem .45rem; border-bottom: 1px solid var(--line);
  }
  .bar h1 { font-size: .8125rem; font-weight: 700; letter-spacing: -.005em; }
  .bar .stamp { font-size: .6875rem; color: var(--faint); margin-left: auto; }
  .bar .stamp b { font-weight: 600; color: var(--muted); }

  /* --- notices: the honesty line, only present when there is something --- */
  .notices {
    flex: 0 0 auto; display: flex; flex-wrap: wrap; gap: .25rem 1rem;
    padding: .3rem .9rem; border-bottom: 1px solid var(--line);
    background: var(--warn-soft); font-size: .6875rem; color: var(--warn);
  }

  /* --- the console grid: one viewport, panels scroll internally --- */
  .grid {
    flex: 1 1 auto; min-height: 0; display: grid; gap: var(--gap); padding: var(--gap);
    grid-template-columns: 1.32fr 1.04fr 1fr;
    grid-template-rows: minmax(0, 1.35fr) minmax(0, 1fr);
    grid-template-areas:
      "review decisions flight"
      "merge  decisions landed";
  }
  [data-panel="review"]    { grid-area: review; }
  [data-panel="merge"]     { grid-area: merge; }
  [data-panel="decisions"] { grid-area: decisions; }
  [data-panel="flight"]    { grid-area: flight; }
  [data-panel="landed"]    { grid-area: landed; }

  @media (max-width: 1180px) {
    .grid {
      grid-template-columns: 1.25fr 1fr;
      grid-template-rows: repeat(3, minmax(0, 1fr));
      grid-template-areas:
        "review    decisions"
        "merge     decisions"
        "flight    landed";
    }
  }
  @media (max-width: 760px), (max-height: 560px) {
    body { overflow: auto; }
    .grid {
      grid-template-columns: 1fr; grid-template-rows: none;
      grid-template-areas: none; height: auto;
    }
    .grid > * { grid-area: auto !important; min-height: 14rem; }
  }

  /* --- a panel groups by its heading and its space; the surface exists to
         say "this region scrolls on its own", not to draw a card --- */
  .panel {
    background: var(--surface); border-radius: 8px; min-height: 0;
    display: flex; flex-direction: column; overflow: hidden;
  }
  .panel > h2 {
    flex: 0 0 auto; display: flex; align-items: baseline; gap: .4rem;
    padding: .55rem var(--pad) .4rem;
    font-size: .6875rem; font-weight: 700; text-transform: uppercase;
    letter-spacing: .07em; color: var(--muted);
  }
  .panel > h2 .count { margin-left: auto; font-weight: 500; color: var(--faint);
                       letter-spacing: 0; text-transform: none; font-size: .6875rem; }
  .scroll { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 0 var(--pad) .6rem; }
  .scroll::-webkit-scrollbar { width: 7px; }
  .scroll::-webkit-scrollbar-thumb { background: var(--line); border-radius: 4px; }
  .scroll::-webkit-scrollbar-track { background: transparent; }

  /* --- rows: hairline rhythm, no boxes; the accent edge is spent only on
         something the captain must act on --- */
  .row { padding: .42rem 0 .45rem; border-top: 1px solid var(--hair); }
  .row:first-child { border-top: none; }
  .row.act { border-left: 2px solid var(--go); padding-left: .5rem; margin-left: -.5rem; }
  .row.held { border-left: 2px solid var(--warn); padding-left: .5rem; margin-left: -.5rem; }
  .row.stopped { border-left: 2px solid var(--stop); padding-left: .5rem; margin-left: -.5rem; }
  .t { font-size: .8125rem; font-weight: 600; line-height: 1.35; }
  .t a { color: inherit; text-decoration: none; }
  .t a:hover { text-decoration: underline; text-underline-offset: 2px; }
  .m { font-size: .71875rem; color: var(--muted); line-height: 1.4; margin-top: .1rem; }
  .m .sep { color: var(--faint); padding: 0 .3rem; }
  .why { font-size: .71875rem; color: var(--warn); line-height: 1.4; margin-top: .12rem; }
  .why.stop { color: var(--stop); }

  /* --- chips: the state is a word first; tone only reinforces it --- */
  .chip {
    display: inline-block; font-size: .5875rem; font-weight: 700; letter-spacing: .06em;
    text-transform: uppercase; padding: .1rem .3rem .05rem; border-radius: 3px;
    vertical-align: .08em; margin-right: .35rem;
    background: var(--info-soft); color: var(--info);
  }
  .chip.go { background: var(--go-soft); color: var(--go); }
  .chip.warn { background: var(--warn-soft); color: var(--warn); }
  .chip.stop { background: var(--stop-soft); color: var(--stop); }
  .chip.quiet { background: transparent; color: var(--faint);
                border: 1px solid var(--line); }

  /* --- decisions: grouped by the work they came from --- */
  .group { padding: .45rem 0 .5rem; border-top: 1px solid var(--hair); }
  .group:first-child { border-top: none; }
  .group h3 { font-size: .75rem; font-weight: 600; margin-bottom: .15rem; }
  .group h3 a { color: inherit; text-decoration: none; }
  .group h3 a:hover { text-decoration: underline; text-underline-offset: 2px; }
  .group ol { list-style: none; counter-reset: d; }
  .group li {
    font-size: .71875rem; color: var(--muted); line-height: 1.4;
    padding: .1rem 0 .1rem 1.1rem; text-indent: -1.1rem;
  }
  .group li::before {
    counter-increment: d; content: counter(d) ". ";
    color: var(--faint); font-variant-numeric: tabular-nums;
  }

  /* --- lanes and their activity feeds --- */
  .lane { padding: .45rem 0 .5rem; border-top: 1px solid var(--hair); }
  .lane:first-child { border-top: none; }
  .lane h3 { font-size: .75rem; font-weight: 600; line-height: 1.35; }
  /* a finished lane stays readable but stops competing with work under way */
  .lane.quiet h3 { color: var(--muted); font-weight: 500; }
  .lane.quiet .feed li:first-child .n { color: var(--muted); }
  .feed { list-style: none; margin-top: .18rem; }
  .feed li { display: flex; gap: .4rem; align-items: baseline; padding: .06rem 0; }
  .feed .v {
    flex: 0 0 4.1rem; font-size: .5875rem; font-weight: 700; text-transform: uppercase;
    letter-spacing: .05em; color: var(--faint); text-align: right; white-space: nowrap;
  }
  .feed .v.done { color: var(--go); }
  .feed .v.needs-decision, .feed .v.paused { color: var(--warn); }
  .feed .v.blocked, .feed .v.failed { color: var(--stop); }
  .feed .n {
    flex: 1 1 auto; min-width: 0; font-size: .6875rem; color: var(--muted);
    line-height: 1.35; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .feed li:first-child .n { color: var(--ink); }

  .empty { font-size: .75rem; color: var(--faint); padding: .5rem 0; }
CSS
}

write_render_program() {  # -> path to the jq render program
  local prog=$TMPWORK/render.jq
  cat > "$prog" <<'JQ'
def e: (. // "") | tostring | @html;
def chip($cls; $word): "<span class=\"chip \($cls)\">\($word | e)</span>";
def sep: "<span class=\"sep\">·</span>";
def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
def clip($n):
  if . == null then null
  elif (. | length) <= $n then .
  else (.[0:$n] | sub("[[:space:]][^[:space:]]*$"; "")) + "…" end;

# The state document keeps the full backlog title; the page shows a label. A
# leading project name repeated on every row of a single-project fleet is noise,
# and a title that wraps to three lines costs a row the captain could have
# scanned in one, so the prefix comes off and the rest is clipped.
def shorten($t; $projects; $n):
  ([ $projects[]? | select(. != null) | split("/") | last | norm ]) as $ps
  | (if ($t | test("^[^:]{1,40}:"))
        and (($t | split(":")[0] | norm) as $h | $ps | index($h)) != null
     then ($t | sub("^[^:]*:[[:space:]]*"; ""))
     else $t end)
  | clip($n);

# A feed line is meant to read as prose. An absolute path or URL inside it is
# navigation the captain cannot click here anyway, so it collapses to the file
# name the worker was talking about.
def readable:
  (. // "")
  # A pull request URL reads as its number, which is how the captain refers to
  # it; any other URL is not clickable from a feed line, so it just says so.
  | gsub("https?://[^[:space:],;)\\]\"'<>]*/(pull|merge_requests)/(?<n>[0-9]+)"; "#\(.n)")
  | gsub("https?://[^[:space:],;)\\]\"'<>]+"; "a link")
  # Any token that carries a slash AND ends in a file extension is a path,
  # absolute or relative, with or without a file:// prefix. Collapse it to the
  # file name; leave owner/repo pairs and other slashed words alone.
  | gsub("(file://)?[^[:space:],;)\\]\"'<>]*/(?<file>[^[:space:]/,;)\\]\"'<>]+\\.[A-Za-z0-9]{1,6})";
        "\(.file)")
  | sub("^[[:space:]]+"; "");

# needs-decision is the only verb that will not fit the feed's gutter, and the
# thing it names to a captain is a decision.
def verb_label: if . == "needs-decision" then "decision" else . end;
def link($href; $text):
  if $href == null then ($text | e)
  else "<a href=\"\($href | @uri | gsub("%3A"; ":") | gsub("%2F"; "/"))\">\($text | e)</a>"
  end;

def type_chip:
  if . == "ui" then chip("go"; "look")
  elif . == "plan" then chip("info"; "read")
  else chip("warn"; "decide") end;

# An empty metadata line still costs a row of height, so it is never emitted.
def meta_line($parts):
  ($parts | map(select(. != null and . != "")) | join("<span class=\"sep\">·</span>")) as $m
  | if $m == "" then "" else "<div class=\"m\">\($m)</div>" end;

def review_row($multi; $names):
  "<div class=\"row act\">"
  + "<div class=\"t\">\(.type | type_chip)\(link(.link; shorten(.title; $names + [.project]; 84)))</div>"
  + meta_line([
      (if .decision_count > 0
       then "\(.decision_count) decision\(if .decision_count == 1 then "" else "s" end) open"
       else empty end),
      (if .link == null and .note != null then (.note | readable | clip(120) | e) else empty end),
      (if $multi then (.project // empty | e) else empty end),
      (if .link == null then "no artifact link recorded" else empty end)
    ])
  + "</div>";

def merge_row($multi; $fetched; $names):
  "<div class=\"row \(if .status == "ready" then "act" else "held" end)\">"
  + "<div class=\"t\">"
  + (if .status == "ready" then chip("go"; "ready") else chip("warn"; "held") end)
  + link(.url; "#\(.number) \(shorten(.title; $names + [.repo]; 68))")
  + "</div>"
  # With no fetched PR data at all, the notice bar already says so once; saying
  # it again on every row would be repetition without information.
  + meta_line([
      (if ($fetched | not) then empty
       elif .checks.state == "passing" then "checks passing"
       elif .checks.state == "none" then "no checks"
       elif .checks.state == "unknown" then "checks unknown"
       else "checks \(.checks.state)" end),
      (if $multi then (.repo // empty | e) else empty end)
    ])
  + ([ .blockers[] | "<div class=\"why\(if .kind == "checks" or .kind == "worker" then " stop" else "" end)\">\(.text | e)</div>" ] | join(""))
  + "</div>";

def decision_group($names):
  "<div class=\"group\"><h3>\(link(.link; shorten(.title; $names + [.project]; 84)))</h3><ol>"
  + ([ .decisions[] | "<li>\(.question | readable | clip(150) | e)</li>" ] | join(""))
  + "</ol></div>";

def lane_row($names):
  "<div class=\"lane\(if .live then "" else " quiet" end)\">"
  + "<h3>"
  + (if .needs_captain then chip("warn"; (.state | verb_label))
     elif (.live | not) then chip("quiet"; .state)
     elif .state == "working" then chip("go"; .state)
     else chip("quiet"; .state) end)
  + (shorten(.title; $names + [.project]; 62) | e) + "</h3>"
  + (if (.activity | length) == 0
     then "<div class=\"m\">no activity recorded yet</div>"
     else "<ul class=\"feed\">"
          + ([ .activity[]
               | "<li><span class=\"v \(.state | e)\">\(.state | verb_label | e)</span>"
                 + "<span class=\"n\">\(.note | readable | e)</span></li>" ] | join(""))
          + "</ul>"
     end)
  + "</div>";

def landed_row($names):
  "<div class=\"row\"><div class=\"t\">\(link(.url; shorten(.title; $names + [.project]; 84)))</div>"
  + "<div class=\"m\">\(.verb | e)\(if .when != null then " \(.when | e)" else "" end)"
  + (if .source != "main" then "<span class=\"sep\">·</span>\(.source | e)" else "" end)
  + "</div></div>";

def panel($key; $heading; $count; $body):
  "<section class=\"panel\" data-panel=\"\($key)\">"
  + "<h2>\($heading)<span class=\"count\">\($count)</span></h2>"
  + "<div class=\"scroll\" data-scroll=\"\($key)\">"
  + (if ($body | length) == 0 then "<div class=\"empty\">Nothing waiting.</div>" else $body end)
  + "</div></section>";

. as $d
| ([$d.awaiting_captain[] | select(.decision_count > 0)]) as $with_decisions
| ([ $d.awaiting_captain[].project, $d.merge_queue[].repo,
     $d.in_flight[].project, $d.completed[].project ]
   | map(select(. != null)) | unique) as $names
# One project inside a panel makes its name pure repetition on every row of that
# panel; two or more make it the thing that tells two rows apart. Decided per
# panel, and compared by repository name, so `big-plan` and `owner/big-plan` are
# not counted as two.
| (([ $d.awaiting_captain[].project ] | map(select(. != null) | split("/") | last)
    | unique | length) > 1) as $multi_review
| (([ $d.merge_queue[].repo ] | map(select(. != null) | split("/") | last)
    | unique | length) > 1) as $multi_merge
| ($d.source.pr_data.present) as $fetched
| "<header class=\"bar\"><h1>Mission control</h1>"
  + "<p class=\"stamp\">updated <b>\($d.generated_display | e)</b>"
  + "<span class=\"sep\">·</span>refreshes every \($d.refresh_seconds)s"
  + "<span class=\"sep\">·</span><span id=\"next\"></span></p></header>"
+ (if ($d.notices | length) > 0
   then "<div class=\"notices\">"
        + ([ $d.notices[] | "<span>\(.text | e)</span>" ] | join(""))
        + "</div>"
   else "" end)
+ "<div class=\"grid\">"
+ panel("review"; "Waiting on you";
    "\($d.counts.ui) to look at, \($d.counts.plan) to read, \($d.counts.decision) to decide";
    ([ $d.awaiting_captain[] | review_row($multi_review; $names) ] | join("")))
+ panel("merge"; "Waiting to merge";
    "\([$d.merge_queue[] | select(.status == "ready")] | length) ready, \([$d.merge_queue[] | select(.status == "held")] | length) held";
    ([ $d.merge_queue[] | merge_row($multi_merge; $fetched; $names) ] | join("")))
+ panel("decisions"; "Decisions";
    "\($d.counts.decisions) open";
    ([ $with_decisions[] | decision_group($names) ] | join("")))
+ panel("flight"; "In flight";
    "\($d.counts.in_flight_live) working, \($d.counts.in_flight - $d.counts.in_flight_live) finished";
    ([ $d.in_flight[] | lane_row($names) ] | join("")))
+ panel("landed"; "Recently landed";
    "\($d.counts.completed)";
    ([ $d.completed[] | landed_row($names) ] | join("")))
+ "</div>"
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
// Offline, self-contained behaviour only.
//
// The page reloads itself on a <meta refresh> because a file:// page cannot
// fetch its own data - Chrome blocks fetch and XMLHttpRequest from a file://
// origin. The page never scrolls, but its panels do, so each panel's scroll
// offset is carried across that reload instead of being silently reset.
(function () {
  var store = null;
  try { store = window.sessionStorage; } catch (e) { store = null; }

  document.querySelectorAll('[data-scroll]').forEach(function (el) {
    var key = 'mc.scroll.' + el.getAttribute('data-scroll');
    if (store) {
      var saved = parseInt(store.getItem(key) || '0', 10);
      if (saved > 0) { el.scrollTop = saved; }
      el.addEventListener('scroll', function () {
        try { store.setItem(key, String(el.scrollTop)); } catch (e) {}
      }, { passive: true });
    }
  });

  // A visible countdown, so a page that looks static is provably still live.
  var meta = document.querySelector('meta[http-equiv="refresh"]');
  var next = document.getElementById('next');
  var left = meta ? parseInt(meta.getAttribute('content') || '0', 10) : 0;
  if (next && left > 0) {
    var tick = function () {
      next.textContent = left > 0 ? 'next in ' + left + 's' : 'refreshing';
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
