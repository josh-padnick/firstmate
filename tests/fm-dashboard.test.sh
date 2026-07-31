#!/usr/bin/env bash
# Behavior tests for the mission-control dashboard: the fm-mission-control.v1
# state document and the page rendered from it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fixed instant keeps the generated stamp and the PR-cache age deterministic.
NOW=2026-07-31T18:00:00Z
export FM_DASHBOARD_NOW=$NOW

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

make_fakebin() {  # <home>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

# A lane standing by for a captain verdict is idle at its harness, and an exact
# idle verdict is what lets its current state come from the status log - which is
# what keeps its open decision authoritative. Recording it here is how a real
# waiting lane looks.
record_idle() {  # <home> <id>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$gen" \
    --source claude-hook --event stop
}

record_busy() {  # <home> <id>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

# One fixture covering every branch the projection has to decide:
#   ship-ui     ship lane, rendered page in its own directory  -> ui
#   scout-plan  scout lane, rendered page in its own directory -> plan (kind wins
#               over the .html extension)
#   ask-only    an open question with no artifact at all       -> decision
#   held-pr     an open PR whose lane is blocked               -> merge_queue held
#   busy-pr     an open PR whose lane is still running          -> the WORKER's turn
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/wt-ship" "$home/projects/wt-scout" "$home/projects/wt-ask" \
    "$home/projects/wt-held" "$home/projects/wt-busy" "$home/data/ship-ui" "$home/data/scout-plan"
  printf '<html><head><title>The rendered table demo</title></head><body></body></html>\n' \
    > "$home/data/ship-ui/demo.html"
  printf '<html><head><title>Styling consolidation</title></head><body></body></html>\n' \
    > "$home/data/scout-plan/plan.html"
  printf '# Scout report\n' > "$home/data/scout-plan/report.md"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-ui - Demo: interactive table component (repo: owner/demo) (kind: ship) (since 2026-07-20)
- [ ] scout-plan - Demo: styling consolidation architecture (repo: owner/demo) (kind: scout) (since 2026-07-21)
- [ ] held-pr - Demo: held pull request lane https://github.com/owner/demo/pull/9 (repo: owner/demo) (kind: ship) (since 2026-07-22)
- [ ] busy-pr - Demo: pull request still being validated https://github.com/owner/demo/pull/12 (repo: owner/demo) (kind: ship) (since 2026-07-24)

## Queued
- [ ] scout-plan-decision-type-ladder - Which type ladder ships (repo: owner/demo) (kind: captain) (since 2026-07-21) (hold: The ladder can carry four steps or three, and the fourth is unused today. Option A, recommended: three steps, because the fourth is never used. Option B: keep four for headroom.) (hold-kind: captain)
  Origin: scout-plan
  Decision key: type-ladder
- [ ] ask-only-decision-naming - What the component is called (repo: owner/demo) (kind: captain) (since 2026-07-23) (hold: Table versus DataTable.) (hold-kind: captain)
  Origin: ask-only
  Decision key: naming

## Done
- [x] landed-one - Demo: first landed change https://github.com/owner/demo/pull/1 (repo: owner/demo) (kind: ship) (merged 2026-07-19)
- [x] landed-two - Demo: second landed change (repo: owner/demo) (kind: ship) (merged 2026-07-18)
- [x] landed-three - Demo: third landed change (repo: owner/demo) (kind: ship) (merged 2026-07-17)
EOF

  fm_write_meta "$home/state/ship-ui.meta" \
    "window=firstmate:fm-ship-ui" "worktree=$home/projects/wt-ship" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  cat > "$home/state/ship-ui.status" <<EOF
working: started on the table component
needs-decision [key=preview-review]: demo ready at file://$home/data/ship-ui/demo.html
paused: standing by for the verdict
EOF

  fm_write_meta "$home/state/scout-plan.meta" \
    "window=firstmate:fm-scout-plan" "worktree=$home/projects/wt-scout" \
    "project=owner/demo" "harness=claude" "kind=scout" "mode=scout" "yolo=off"
  cat > "$home/state/scout-plan.status" <<EOF
working: reading the stylesheet
done: plan rendered at file://$home/data/scout-plan/plan.html
EOF

  fm_write_meta "$home/state/ask-only.meta" \
    "window=firstmate:fm-ask-only" "worktree=$home/projects/wt-ask" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  cat > "$home/state/ask-only.status" <<EOF
needs-decision [key=naming]: name the component before it ships
paused: standing by for the name
EOF

  fm_write_meta "$home/state/held-pr.meta" \
    "window=firstmate:fm-held-pr" "worktree=$home/projects/wt-held" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "pr=https://github.com/owner/demo/pull/9"
  cat > "$home/state/held-pr.status" <<EOF
needs-decision [key=scope]: confirm the migration scope before merge
paused: standing by before merging
EOF

  # The captain's own example: an open pull request whose lane is mid-pipeline.
  # It is open, it has no blocker, and it is still not his to merge.
  fm_write_meta "$home/state/busy-pr.meta" \
    "window=firstmate:fm-busy-pr" "worktree=$home/projects/wt-busy" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "pr=https://github.com/owner/demo/pull/12"
  printf 'working: validation running\n' > "$home/state/busy-pr.status"

  # Blocked with nobody on it: the lane reported a blocker and its worker is
  # gone. This is the case the captain must be able to spot without asking.
  mkdir -p "$home/projects/wt-stalled"
  fm_write_meta "$home/state/stalled-lane.meta" \
    "window=firstmate:fm-gone" "worktree=$home/projects/wt-stalled" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'blocked: upstream API returns 500 and I cannot get past it\n' \
    > "$home/state/stalled-lane.status"

  # Ownership genuinely unverifiable: no endpoint was ever recorded, so we must
  # say we cannot tell rather than guess either way.
  mkdir -p "$home/projects/wt-unknown"
  fm_write_meta "$home/state/unverified-lane.meta" \
    "worktree=$home/projects/wt-unknown" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'blocked: waiting on something unclear\n' > "$home/state/unverified-lane.status"

  record_idle "$home" ship-ui
  record_idle "$home" scout-plan
  record_idle "$home" ask-only
  record_idle "$home" held-pr
  record_busy "$home" busy-pr
  record_idle "$home" stalled-lane
}

capture() {  # <home> -> snapshot path
  local home=$1 fakebin out=$TMP_ROOT/snap-$$.json
  fakebin=$(make_fakebin "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json > "$out" || return 1
  printf '%s' "$out"
}

state_for() {  # <home> -> state document on stdout
  local home=$1 snap
  snap=$(capture "$home") || fail "snapshot failed for $home"
  FM_HOME="$home" "$DASH" --snapshot "$snap" --json
}

test_empty_home_is_honest() {
  local home out html
  home=$(make_home empty)
  out=$(state_for "$home") || fail "empty projection failed"
  printf '%s' "$out" | jq -e '
    .schema == "fm-mission-control.v1"
      and .generated == "2026-07-31T18:00:00Z"
      and (.merge_queue | length) == 0
      and (.awaiting_captain | length) == 0
      and (.in_flight | length) == 0
      and (.completed | length) == 0
      and .source.pr_data.present == false
      and .source.pr_data.stale == true
      and (.notices | map(.kind) | index("pr-data")) != null
  ' >/dev/null || fail "empty state document wrong: $out"

  printf '%s' "$out" > "$TMP_ROOT/empty.json"
  html=$("$DASH" --render "$TMP_ROOT/empty.json") || fail "empty render failed"
  assert_contains "$html" "All caught up" "an empty queue should say so rather than look broken"
  pass "an empty home renders a valid, explicitly empty board"
}

test_typed_awaiting_queue() {
  local home out
  home=$(make_home typed)
  write_fixture "$home"
  out=$(state_for "$home") || fail "typed projection failed"

  printf '%s' "$out" | jq -e '
    .awaiting_captain | map({id, type, link_kind}) as $rows
    | ($rows | map(select(.id == "ship-ui")) | .[0].type) == "ui"
      and ($rows | map(select(.id == "scout-plan")) | .[0].type) == "plan"
      and ($rows | map(select(.id == "ask-only")) | .[0].type) == "decision"
  ' >/dev/null || fail "typing wrong: $(printf '%s' "$out" | jq -c '[.awaiting_captain[]|{id,type}]')"

  # The scout deliverable renders as HTML too, so the extension cannot be what
  # decides; the dispatch kind must be.
  printf '%s' "$out" | jq -e '
    .awaiting_captain[] | select(.id == "scout-plan")
    | (.link | endswith("/plan.html")) and .type == "plan" and .kind == "scout"
  ' >/dev/null || fail "a scout deliverable rendered as HTML must still be a plan to read"

  printf '%s' "$out" | jq -e '
    .awaiting_captain[] | select(.id == "ask-only") | .link == null
  ' >/dev/null || fail "an ask with no artifact must not invent a link"

  # Four bare questions with no artifact: ask-only, the held PR, and the two
  # blocked lanes. A blocked lane is the captain's to clear too, so it belongs
  # in the same queue rather than only in a status log.
  printf '%s' "$out" | jq -e '
    .counts.ui == 1 and .counts.plan == 1 and .counts.decision == 4
      and .counts.awaiting_captain == 6
  ' >/dev/null || fail "typed counts wrong: $(printf '%s' "$out" | jq -c .counts)"
  pass "review queue is typed by what the work produces, not by file extension"
}

test_titles_and_links_are_real() {
  local home out
  home=$(make_home titles)
  write_fixture "$home"
  out=$(state_for "$home")

  # A link is published only when the file exists on disk.
  printf '%s' "$out" | jq -e '
    [ .awaiting_captain[] | select(.link != null) | .link ]
    | all(startswith("file:///") or startswith("http"))
  ' >/dev/null || fail "published links must be openable URLs"

  printf '%s' "$out" | jq -e '
    .awaiting_captain[] | select(.id == "ship-ui") | .link | endswith("/demo.html")
  ' >/dev/null || fail "a lane's own rendered page should win over anything else"
  pass "links resolve to files this home actually has"
}

test_decision_queue_dedupes_against_status() {
  local home out
  home=$(make_home decisions)
  write_fixture "$home"
  out=$(state_for "$home")

  # ask-only has BOTH a durable captain hold (key naming) and a live
  # needs-decision line carrying the same key. It is one decision.
  printf '%s' "$out" | jq -e '
    [ .awaiting_captain[] | select(.id == "ask-only") | .decisions[] ] | length == 1
  ' >/dev/null || fail "a decision filed as a hold and still open in status is one decision: \
$(printf '%s' "$out" | jq -c '[.awaiting_captain[]|select(.id=="ask-only")|.decisions]')"

  printf '%s' "$out" | jq -e '
    (.counts.decisions) == ([ .awaiting_captain[] | .decision_count ] | add)
  ' >/dev/null || fail "the decision count must equal the queue it is derived from"
  pass "the decision queue is one set, deduped against the durable hold"
}

test_merge_queue_names_its_blockers() {
  local home out
  home=$(make_home merge)
  write_fixture "$home"
  out=$(state_for "$home")

  printf '%s' "$out" | jq -e '
    .merge_queue[] | select(.number == 9)
    | .status == "held"
      and (.blockers | map(.kind) | index("decision")) != null
      and (.blockers[] | select(.kind == "decision") | .text | test("migration scope"))
  ' >/dev/null || fail "a PR whose lane is waiting on a decision must be held, and say why: \
$(printf '%s' "$out" | jq -c .merge_queue)"

  printf '%s' "$out" | jq -e '
    [ .merge_queue[] | select(.status == "held") ] | all((.blockers | length) > 0)
  ' >/dev/null || fail "held must mean at least one named blocker"

  printf '%s' "$out" | jq -e '
    .merge_queue[] | select(.number == 9) | .checks.source == "not-fetched"
  ' >/dev/null || fail "check state must admit it was never fetched"
  pass "merge queue marks held work and names what blocks it"
}

test_activity_feed_is_newest_first() {
  local home out
  home=$(make_home feed)
  write_fixture "$home"
  out=$(state_for "$home")

  printf '%s' "$out" | jq -e '
    .in_flight[] | select(.id == "ship-ui")
    | (.feed | length) == 3
      and (.feed | map(.state)) == ["paused", "needs-decision", "working"]
      and (.feed[2].note == "started on the table component")
  ' >/dev/null || fail "each lane carries its own newest-first feed: \
$(printf '%s' "$out" | jq -c '[.in_flight[]|select(.id=="ship-ui")|.feed]')"

  printf '%s' "$out" | jq -e '
    [ .in_flight[] | .kind ] | index("secondmate") == null
  ' >/dev/null || fail "an idle secondmate must not be drawn as an in-flight lane"
  pass "every lane shows its own activity feed, newest first"
}

test_completed_retention_is_disclosed() {
  local home out
  home=$(make_home completed)
  write_fixture "$home"
  out=$(FM_DASHBOARD_COMPLETED=2 FM_HOME="$home" "$DASH" --snapshot "$(capture "$home")" --json)

  printf '%s' "$out" | jq -e '
    (.completed | length) == 2
      and (.completed[0].when >= .completed[1].when)
      and (.notices | map(.kind) | index("retention")) != null
  ' >/dev/null || fail "dropping landed rows must be disclosed: $(printf '%s' "$out" | jq -c '{c:.completed,n:.notices}')"
  pass "trimmed landed history is disclosed, never silently truncated"
}

test_pr_cache_ages_and_is_local_only() {
  local home out fakebin snap
  home=$(make_home prcache)
  write_fixture "$home"
  snap=$(capture "$home")
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) printf '[]\n' ;;
  *"pr view"*)
    printf '{"number":9,"title":"Held pull request lane","url":"https://github.com/owner/demo/pull/9","state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$DASH" --snapshot "$snap" \
    --out-dir "$home/data" --refresh-prs >/dev/null || fail "--refresh-prs failed"
  [ -f "$home/state/dashboard-prs.json" ] || fail "--refresh-prs must write the cache"

  # A later regeneration reads the cache and must not need the network at all.
  out=$(FM_HOME="$home" "$DASH" --snapshot "$snap" --json)
  printf '%s' "$out" | jq -e '
    .source.pr_data.present == true
      and .source.pr_data.stale == false
      and (.merge_queue[] | select(.number == 9)
           | .checks.state == "failing"
             and .checks.source == "pr-cache"
             and (.blockers | map(.kind) | index("checks")) != null)
  ' >/dev/null || fail "cached check state must reach the merge row: $(printf '%s' "$out" | jq -c .merge_queue)"

  # Age the same cache by an hour; past its time to live it reads stale and the
  # board says so instead of presenting hour-old checks as current.
  jq '.fetched = "2026-07-31T17:00:00Z"' "$home/state/dashboard-prs.json" \
    > "$home/state/aged.json" && mv "$home/state/aged.json" "$home/state/dashboard-prs.json"
  out=$(FM_HOME="$home" "$DASH" --snapshot "$snap" --json)
  printf '%s' "$out" | jq -e '
    .source.pr_data.stale == true
      and .source.pr_data.age_seconds == 3600
      and (.notices | map(select(.kind == "pr-data")) | length) == 1
      and (.notices[] | select(.kind == "pr-data") | .text | test("60 minutes old"))
  ' >/dev/null || fail "an aged PR cache must be disclosed as stale: \
$(printf '%s' "$out" | jq -c '{pr:.source.pr_data,n:.notices}')"
  pass "PR data is fetched only on request, cached, aged, and disclosed"
}

test_page_is_self_contained_and_escapes_hostile_text() {
  local home state html
  home=$(make_home render)
  write_fixture "$home"
  printf 'blocked: <script>alert("x")</script> & "quoted" text\n' \
    >> "$home/state/ship-ui.status"
  state=$TMP_ROOT/render-state.json
  state_for "$home" > "$state"
  html=$("$DASH" --render "$state") || fail "render failed"

  assert_contains "$html" 'http-equiv="refresh"' "the page must carry its own refresh instruction"
  assert_contains "$html" 'id="mission-control-state"' "the page must embed the document it renders"
  assert_contains "$html" 'id="queue"' "the dominant attention queue must be rendered"
  assert_contains "$html" "Needs your attention" "the queue must be named for the question it answers"
  assert_contains "$html" "Active work" "the active-work summary must be rendered"
  assert_contains "$html" "Recently landed" "the landed summary must be rendered"

  # Self-contained: nothing is loaded from anywhere.
  assert_not_contains "$html" '<script src=' "no external script may be loaded"
  assert_not_contains "$html" '<link rel="stylesheet"' "no external stylesheet may be loaded"
  assert_not_contains "$html" 'fetch(' "the page must not try to fetch data it cannot fetch"

  # Hostile status text must never become markup, in the body or in the
  # embedded state document.
  assert_not_contains "$html" '<script>alert' "status text must be escaped, not executed"
  assert_contains "$html" '&lt;script&gt;alert' "status text should appear escaped"
  pass "the page is self-contained, panelled, and escapes worker-authored text"
}

test_render_refuses_a_foreign_document() {
  local out code=0
  printf '{"schema":"something-else"}' > "$TMP_ROOT/foreign.json"
  out=$("$DASH" --render "$TMP_ROOT/foreign.json" 2>&1) || code=$?
  [ "$code" -ne 0 ] || fail "rendering a foreign document must fail"
  assert_contains "$out" "fm-mission-control.v1" "the refusal should name the document it needs"
  pass "the renderer refuses anything that is not a mission-control document"
}

test_html_is_a_rendering_of_the_written_document() {
  local home snap
  home=$(make_home roundtrip)
  write_fixture "$home"
  snap=$(capture "$home")
  FM_HOME="$home" "$DASH" --snapshot "$snap" --out-dir "$home/out" >/dev/null \
    || fail "write failed"
  [ -f "$home/out/mission-control.json" ] || fail "the state document must be written"
  [ -f "$home/out/mission-control.html" ] || fail "the page must be written"

  # Rendering the written document again must reproduce the written page byte
  # for byte: the page is a function of the document and nothing else.
  "$DASH" --render "$home/out/mission-control.json" > "$home/out/again.html" \
    || fail "re-render failed"
  cmp -s "$home/out/mission-control.html" "$home/out/again.html" \
    || fail "the page must be reproducible from the state document alone"
  pass "the page is exactly a rendering of the state document that ships with it"
}

test_turn_says_whose_move_it_is() {
  local home out
  home=$(make_home turns)
  write_fixture "$home"
  out=$(state_for "$home") || fail "turn projection failed"

  # The captain's own case: open, unblocked, and still not his, because the lane
  # that owns it has not finished.
  printf '%s' "$out" | jq -e '
    .merge_queue[] | select(.number == 12)
    | .turn == "worker" and .action == null
      and (.headline | startswith("Blocked on"))
      and (.activity.text | test("validation running"))
  ' >/dev/null || fail "a pull request whose lane is still running is not the captain's turn: \
$(printf '%s' "$out" | jq -c '[.merge_queue[]|{number,turn,headline}]')"

  # A question of his is his turn, and says so outright.
  printf '%s' "$out" | jq -e '
    .merge_queue[] | select(.number == 9)
    | .turn == "captain" and .action == "decide" and .headline == "Yours to decide"
  ' >/dev/null || fail "a PR held on the captain's decision must read as his turn"

  printf '%s' "$out" | jq -e '
    [ .merge_queue[], .awaiting_captain[], .in_flight[] ]
    | all(.turn | IN("captain", "worker", "external"))
      and all(.headline != null and .headline != "")
      and all(.activity.text != null and .activity.source != null)
      and all(if .turn == "captain" then .action != null else .action == null end)
  ' >/dev/null || fail "every item must carry a turn, a headline, an activity, and an action only when it is the captain's"

  # A busy pane is evidence the worker is busy, not evidence about validation.
  printf '%s' "$out" | jq -e '
    .merge_queue[] | select(.number == 12) | .activity.source == "status-log"
  ' >/dev/null || fail "activity must name the evidence it came from"

  printf '%s' "$out" | jq -e '
    .counts.inbox == ([ .merge_queue[], .awaiting_captain[], .in_flight[] ]
                      | map(select(.turn == "captain") | .id) | unique | length)
  ' >/dev/null || fail "the inbox count must be the deduped captain-turn set"
  pass "every item says whose turn it is, what it is waiting for, and what is happening now"
}

test_decisions_carry_their_recommendation() {
  local home out
  home=$(make_home recs)
  write_fixture "$home"
  out=$(state_for "$home")

  # Stated by the plan, in the phrasing real holds use, and recovered from the
  # raw row because the canonical parser truncates hold_reason at a comma.
  printf '%s' "$out" | jq -e '
    .awaiting_captain[] | select(.id == "scout-plan") | .decisions[0]
    | .recommendation == "Option A: three steps, because the fourth is never used."
      and .recommendation_source == "hold"
      and .reasoning == null
  ' >/dev/null || fail "a stated recommendation must be carried inline: \
$(printf '%s' "$out" | jq -c '[.awaiting_captain[]|select(.id=="scout-plan")|.decisions]')"

  # None stated: the reasoning stands in so the row is still answerable.
  printf '%s' "$out" | jq -e '
    .awaiting_captain[] | select(.id == "ask-only") | .decisions[0]
    | .recommendation == null and .reasoning == "Table versus DataTable."
  ' >/dev/null || fail "with no recommendation the hold reasoning must stand in: \
$(printf '%s' "$out" | jq -c '[.awaiting_captain[]|select(.id=="ask-only")|.decisions]')"

  printf '%s' "$out" | jq -e '
    .awaiting_captain[] | select(.id == "scout-plan") | .recommended_count == 1
  ' >/dev/null || fail "recommended_count must count decisions that carry one"
  pass "decisions carry the recommended answer, or the reasoning when none was stated"
}

test_inbox_view_ships_beside_the_panels() {
  local home state html
  home=$(make_home inbox)
  write_fixture "$home"
  state=$TMP_ROOT/inbox-state.json
  state_for "$home" > "$state"
  html=$("$DASH" --render "$state") || fail "render failed"

  # Both views, in one artifact, so the captain can compare them.
  assert_contains "$html" 'id="view-panels"' "the panel view must still ship"
  assert_contains "$html" 'id="view-inbox"' "the inbox view must ship beside it"
  assert_contains "$html" 'data-view="inbox"' "there must be a way to switch to it"
  assert_contains "$html" 'data-filter="turn"' "the inbox must filter by turn"
  assert_contains "$html" 'data-filter="kind"' "the inbox must filter by type"
  assert_contains "$html" 'data-turn="captain"' "inbox rows must be filterable by turn"

  # The badge is the inbox size, taken from the document rather than counted in
  # the page, so the two can never drift.
  local inbox
  inbox=$(jq -r '.counts.inbox' "$state")
  assert_contains "$html" ">$inbox</span>" "the inbox badge must show the document's own count"
  pass "the experimental inbox ships alongside the panels, filtered by type and turn"
}

test_blocked_says_whether_anyone_is_on_it() {
  local home out
  home=$(make_home attended)
  write_fixture "$home"
  out=$(state_for "$home") || fail "attendance projection failed"

  # A worker the backend reports busy is positive evidence someone is on it.
  printf '%s' "$out" | jq -e '
    .merge_queue[] | select(.number == 12)
    | .attended == true and .attended_by == "worker"
      and .attended_evidence == "live-endpoint"
  ' >/dev/null || fail "a busy worker must read as being worked on: \
$(printf '%s' "$out" | jq -c '[.merge_queue[]|{number,attended,attended_by,attended_evidence}]')"

  # Blocked with the worker gone is the case that needs saying outright.
  printf '%s' "$out" | jq -e '
    .in_flight[] | select(.id == "stalled-lane")
    | .attended == false and .attended_by == null
      and (.attended_evidence | IN("no-endpoint", "idle-endpoint"))
  ' >/dev/null || fail "a blocked lane with no worker must read as unattended: \
$(printf '%s' "$out" | jq -c '[.in_flight[]|{id,state,attended,attended_evidence}]')"

  # Unverifiable ownership is its own answer, never guessed either way.
  printf '%s' "$out" | jq -e '
    .in_flight[] | select(.id == "unverified-lane")
    | .attended == null and .attended_evidence == "unverified"
  ' >/dev/null || fail "unverifiable ownership must stay null, not be guessed: \
$(printf '%s' "$out" | jq -c '[.in_flight[]|select(.id=="unverified-lane")]')"

  printf '%s' "$out" | jq -e '
    [ .merge_queue[], .awaiting_captain[], .in_flight[] ]
    | all(has("attended") and has("attended_evidence"))
  ' >/dev/null || fail "every item must carry attendance, so ownership is never silent"
  pass "blocked work says whether someone is on it, or that we cannot tell"
}

test_redesign_shape() {
  local home state html
  home=$(make_home shape)
  write_fixture "$home"
  state=$TMP_ROOT/shape-state.json
  state_for "$home" > "$state"
  html=$("$DASH" --render "$state") || fail "render failed"

  # The captain works from this page and must not lose it.
  local links newtab
  links=$(printf '%s' "$html" | grep -c '<a class="go"' || true)
  newtab=$(printf '%s' "$html" | grep -c 'class="go" href=[^>]*target="_blank"' || true)
  [ "$links" -gt 0 ] || fail "the queue must offer actions to open"
  [ "$links" = "$newtab" ] || fail "every queue action must open in a new tab ($newtab of $links)"

  # A plan carrying decisions is ONE row, with its questions behind expansion -
  # not duplicated as a separate decisions column.
  assert_not_contains "$html" 'data-panel="decisions"' "the separate decisions column must be gone"
  assert_contains "$html" '<details class="item"' "a row with questions must expand in place"
  assert_contains "$html" 'Recommended:' "a recommended answer must be readable in the row"

  # Relative time, not repeated ISO dates.
  printf '%s' "$html" | grep -qE '<span class="when">(just now|[0-9]+[mhd]|yesterday)</span>' \
    || fail "the queue must show human elapsed time"

  # Progressive disclosure for the activity log.
  assert_contains "$html" '<details class="lane' "workstream events must sit behind expansion"
  pass "the board leads with one queue, folds decisions into their plan, and opens in new tabs"
}

test_empty_home_is_honest
test_typed_awaiting_queue
test_blocked_says_whether_anyone_is_on_it
test_redesign_shape
test_turn_says_whose_move_it_is
test_decisions_carry_their_recommendation
test_inbox_view_ships_beside_the_panels
test_titles_and_links_are_real
test_decision_queue_dedupes_against_status
test_merge_queue_names_its_blockers
test_activity_feed_is_newest_first
test_completed_retention_is_disclosed
test_pr_cache_ages_and_is_local_only
test_page_is_self_contained_and_escapes_hostile_text
test_render_refuses_a_foreign_document
test_html_is_a_rendering_of_the_written_document
