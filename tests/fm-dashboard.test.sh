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
    "$home/projects/wt-held" "$home/projects/wt-busy" "$home/projects/wt-parked" \
    "$home/data/ship-ui" "$home/data/scout-plan"
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
- [ ] parked-pr - Demo: pull request parked at review https://github.com/owner/demo/pull/15 (repo: owner/demo) (kind: ship) (since 2026-07-25)

## Queued
- [ ] scout-plan-decision-type-ladder - Which type ladder ships (repo: owner/demo) (kind: captain) (since 2026-07-21) (hold: The ladder can carry four steps or three, and the fourth is unused today. Option A, recommended: three steps, because the fourth is never used. Option B: keep four for headroom.) (hold-kind: captain)
  Origin: scout-plan
  Decision key: type-ladder
- [ ] ask-only-decision-naming - What the component is called (repo: owner/demo) (kind: captain) (since 2026-07-23) (hold: Table versus DataTable.) (hold-kind: captain)
  Origin: ask-only
  Decision key: naming
- [ ] held-pr-decision-scope - Confirm the migration scope before merge (repo: owner/demo) (kind: captain) (since 2026-07-22) (hold: Keep the migration within the current package.) (hold-kind: captain)
  Origin: held-pr
  Decision key: scope

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

  fm_write_meta "$home/state/parked-pr.meta" \
    "window=firstmate:fm-parked-pr" "worktree=$home/projects/wt-parked" \
    "project=owner/demo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "pr=https://github.com/owner/demo/pull/15"
  printf 'parked: waiting at the review gate\n' > "$home/state/parked-pr.status"

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
  record_idle "$home" parked-pr
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
    .schema == "fm-mission-control.v2"
      and .generated == "2026-07-31T18:00:00Z"
      and (.updates | length) == 0
      and (.tasks | length) == 0
      and .source.pr_data.present == false
      and .source.pr_data.stale == true
      and (.notices | map(.kind) | index("pr-data")) != null
  ' >/dev/null || fail "empty state document wrong: $out"

  printf '%s' "$out" > "$TMP_ROOT/empty.json"
  html=$("$DASH" --render "$TMP_ROOT/empty.json") || fail "empty render failed"
  assert_contains "$html" "All caught up" "an empty queue should say so rather than look broken"
  pass "an empty home renders a valid, explicitly empty board"
}

test_updates_are_only_plans_and_prs() {
  local home out
  home=$(make_home typed)
  write_fixture "$home"
  out=$(state_for "$home") || fail "projection failed"

  # The captain's model: exactly two kinds of thing need his attention.
  printf '%s' "$out" | jq -e '
    [.updates[].kind] | unique | inside(["plan", "pr"])
  ' >/dev/null || fail "an update must only ever be a plan or a pull request: \
$(printf '%s' "$out" | jq -c '[.updates[].kind] | unique')"

  # The finer read-vs-look distinction is preserved, not discarded, and still
  # decided by dispatch kind rather than file extension.
  printf '%s' "$out" | jq -e '
    (.updates[] | select(.task_id == "ship-ui") | .detail_type) == "ui"
      and (.updates[] | select(.task_id == "scout-plan") | .detail_type) == "plan"
      and (.updates[] | select(.task_id == "scout-plan") | .link | endswith("/plan.html"))
  ' >/dev/null || fail "detail typing lost: $(printf '%s' "$out" | jq -c '[.updates[]|{task_id,detail_type}]')"

  # An update points AT a task; it is not one.
  printf '%s' "$out" | jq -e '
    ([.updates[] | select(.task_id != null)] | length) == (.updates | length)
  ' >/dev/null || fail "every update must name the task it concerns"

  printf '%s' "$out" | jq -e '
    .counts.plans + .counts.prs == .counts.updates
  ' >/dev/null || fail "counts wrong: $(printf '%s' "$out" | jq -c .counts)"
  pass "the inbox holds updates, only ever plans or pull requests, each naming its task"
}

test_one_task_component_both_states() {
  local home out
  home=$(make_home tasks)
  write_fixture "$home"
  out=$(state_for "$home") || fail "projection failed"

  # A task is the same object whether running or landed: one collection, one
  # shape, filtered by status.
  printf '%s' "$out" | jq -e '
    (.tasks | length) > 0
      and ([.tasks[] | select(.status == "landed")] | length) > 0
      and ([.tasks[] | select(.status != "landed")] | length) > 0
  ' >/dev/null || fail "tasks must cover both active and landed work"

  printf '%s' "$out" | jq -e '
    ([.tasks[] | keys] | unique | length) == 1
  ' >/dev/null || fail "every task must have the identical shape: \
$(printf '%s' "$out" | jq -c '[.tasks[] | keys] | unique | map(length)')"

  printf '%s' "$out" | jq -e '
    [.tasks[]] | all(has("type") and has("agent") and has("status")
                     and has("activity") and has("history") and has("live"))
  ' >/dev/null || fail "a task must carry type, agent, status, last action, history and liveness"

  # The agent is real data, named as the captain names them.
  printf '%s' "$out" | jq -e '
    [.tasks[] | select(.agent != null) | .agent] | any(. == "Claude")
  ' >/dev/null || fail "the agent running a task must be named: \
$(printf '%s' "$out" | jq -c '[.tasks[]|{id,agent}]')"

  # Where the product has no data yet, null - never an invented value.
  printf '%s' "$out" | jq -e '
    [.updates[] | .version] | all(. == null)
  ' >/dev/null || fail "version must stay null until the product has versions"
  pass "one task component covers active and landed work, with agent, status and history"
}

test_titles_and_links_are_real() {
  local home out
  home=$(make_home titles)
  write_fixture "$home"
  out=$(state_for "$home")

  # A link is published only when the file exists on disk.
  printf '%s' "$out" | jq -e '
    [ .updates[] | select(.kind == "plan") | select(.link != null) | .link ]
    | all(startswith("file:///") or startswith("http"))
  ' >/dev/null || fail "published links must be openable URLs"

  printf '%s' "$out" | jq -e '
    .updates[] | select(.task_id == "ship-ui") | .link | endswith("/demo.html")
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
    ([ .updates[] | select(.task_id == "ask-only") | .decisions[] ] | length) == 1
  ' >/dev/null || fail "a decision filed as a hold and still open in status is one decision: \
$(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "plan")|select(.id=="ask-only")|.decisions]')"

  printf '%s' "$out" | jq -e '
    ([.updates[] | select(.kind == "plan") | .decision_count] | add // 0)
      == ([.updates[] | select(.kind == "plan") | (.decisions | length)] | add // 0)
  ' >/dev/null || fail "each plan's decision count must match the questions it carries"
  pass "the decision queue is one set, deduped against the durable hold"
}

test_merge_queue_names_its_blockers() {
  local home out
  home=$(make_home merge)
  write_fixture "$home"
  out=$(state_for "$home")

  printf '%s' "$out" | jq -e '
    .updates[] | select(.kind == "pr") | select(.number == 9)
    | .turn == "captain" and .action == "decide"
      and (.blockers | map(.kind) | index("decision")) != null
      and (.blockers[] | select(.kind == "decision") | .text | test("migration scope"))
  ' >/dev/null || fail "a PR whose lane is waiting on a decision must be held, and say why: \
$(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "pr")]')"

  printf '%s' "$out" | jq -e '
    [.updates[] | select(.kind == "pr") | select(.turn != "captain")]
    | all((.blockers | length) > 0 or (.headline | startswith("Blocked on")))
  ' >/dev/null || fail "a PR that is not the captain's must say what it waits on"

  printf '%s' "$out" | jq -e '
    .updates[] | select(.kind == "pr") | select(.number == 9) | .checks.source == "not-fetched"
  ' >/dev/null || fail "check state must admit it was never fetched"
  pass "merge queue marks held work and names what blocks it"
}

test_merge_queue_uses_authoritative_waits() {
  local home out state html snap
  home=$(make_home merge-authority)
  write_fixture "$home"
  printf 'paused: durable decision remains open\n' > "$home/state/held-pr.status"
  printf 'done: validation finished\n' > "$home/state/busy-pr.status"
  record_idle "$home" held-pr
  record_idle "$home" busy-pr
  snap=$(capture "$home")
  jq '(.tasks[] | select(.id == "parked-pr") | .current_state)
      = {state:"parked", source:"run-step", detail:"parked at review"}' \
    "$snap" > "$TMP_ROOT/merge-authority-snapshot.json"
  out=$(FM_HOME="$home" "$DASH" --snapshot "$TMP_ROOT/merge-authority-snapshot.json" --json)

  printf '%s' "$out" | jq -e '
    (.updates[] | select(.kind == "pr") | select(.number == 15)
     | .turn == "captain" and .action == "decide"
       and .waiting_for == "your decision at a gate")
    and
    (.updates[] | select(.kind == "pr") | select(.number == 12)
     | .turn == "external" and .action == null
       and .checks.state == "unknown"
       and any(.blockers[]; .kind == "checks" and (.text | test("not fetched"))))
    and
    (.updates[] | select(.kind == "pr") | select(.number == 9)
     | .turn == "captain"
       and any(.blockers[]; .kind == "decision"
               and (.text | test("migration scope"))))
  ' >/dev/null || fail "merge rows must use parked state, check certainty, and durable decisions: \
$(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "pr")|{number,status,turn,waiting_for,blockers}]')"

  state=$TMP_ROOT/merge-authority.json
  printf '%s' "$out" > "$state"
  html=$("$DASH" --render "$state") || fail "authoritative merge render failed"
  # Inline expansion is gone, but the guarantee behind it stands: every row is
  # addressed by a stable identity, never by its position in the list.
  assert_contains "$html" 'data-task="scout-plan"' "rows must carry a stable task identity"
  printf '%s' "$html" | grep -qE "open\.[a-z]*\.[0-9]+" \
    && fail "persisted state must not be keyed by row position"
  assert_contains "$html" 'data-priority="0"' "stuck rows must carry their urgency into client-side sorting"
  pass "merge turns, blockers, sort rank, and expansion identity use authoritative state"
}

test_promoted_scout_report_cannot_mask_pr() {
  local home out state html snap report url
  home=$(make_home promoted)
  write_fixture "$home"
  report=$home/data/ship-ui/report.md
  url=https://github.com/owner/demo/pull/21
  printf '# Original scout report\n' > "$report"
  snap=$(capture "$home")
  jq --arg report "$report" --arg url "$url" '
    (.tasks[] | select(.id == "ship-ui")) |= (
      .kind = "ship"
      | .current_state = {state:"done", source:"run-step", detail:"checks green"}
      | .hints.open_decisions = []
      | .paths.report = {present:true, path:$report}
      | .pr = {url:$url}
    )
  ' "$snap" > "$TMP_ROOT/promoted-snapshot.json"
  jq -n --arg fetched "$NOW" --arg url "$url" '{
    fetched:$fetched,
    records:[{
      url:$url, reachable:true, number:21, title:"Promoted scout change",
      state:"OPEN", draft:false, merged:false,
      checks:{state:"passing", summary:"1 passed, 0 failed, 1 total"}
    }]
  }' > "$home/state/dashboard-prs.json"
  out=$(FM_HOME="$home" "$DASH" --snapshot "$TMP_ROOT/promoted-snapshot.json" --json)

  printf '%s' "$out" | jq -e '
    ([.updates[] | select(.kind == "plan") | select(.task_id == "ship-ui")] | length) == 0
    and
    (.updates[] | select(.kind == "pr") | select(.task_id == "ship-ui")
     | .number == 21 and .turn == "captain" and .action == "merge"
       and (.blockers | length) == 0)
  ' >/dev/null || fail "a promoted scout report must not mask its ready pull request: \
$(printf '%s' "$out" | jq -c '{awaiting:.updates,merge:[.updates[] | select(.kind == "pr")]}')"

  state=$TMP_ROOT/promoted-state.json
  printf '%s' "$out" > "$state"
  html=$("$DASH" --render "$state") || fail "promoted scout render failed"
  assert_contains "$html" '#21 ' "the promoted ship must render as its pull request"
  # The inbox labels an update by kind; its action verb rides the open control.
  assert_contains "$html" '>PR</span>' "the promoted ship must render labelled as a pull request"
  pass "a promoted scout report cannot mask its ready pull request"
}

test_activity_feed_is_newest_first() {
  local home out
  home=$(make_home feed)
  write_fixture "$home"
  out=$(state_for "$home")

  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-ui")
    | (.history | length) == 3
      and (.history | map(.state)) == ["paused", "needs-decision", "working"]
      and (.history[2].note == "started on the table component")
  ' >/dev/null || fail "each lane carries its own newest-first feed: \
$(printf '%s' "$out" | jq -c '[.tasks[]|select(.id=="ship-ui")|.history]')"

  printf '%s' "$out" | jq -e '
    [ .tasks[] | .dispatch_kind ] | index("secondmate") == null
  ' >/dev/null || fail "an idle secondmate must not be drawn as an in-flight lane"
  pass "every lane shows its own activity feed, newest first"
}

test_completed_retention_is_disclosed() {
  local home out
  home=$(make_home completed)
  write_fixture "$home"
  out=$(FM_DASHBOARD_COMPLETED=2 FM_HOME="$home" "$DASH" --snapshot "$(capture "$home")" --json)

  printf '%s' "$out" | jq -e '
    ([.tasks[] | select(.status == "landed")] | length) == 2
      and (.notices | map(.kind) | index("retention")) != null
  ' >/dev/null || fail "dropping landed rows must be disclosed: $(printf '%s' "$out" | jq -c '{landed:[.tasks[]|select(.status=="landed")|.id],n:.notices}')"
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
      and (.updates[] | select(.kind == "pr") | select(.number == 9)
           | .checks.state == "failing"
             and .checks.source == "pr-cache"
             and (.blockers | map(.kind) | index("checks")) != null)
  ' >/dev/null || fail "cached check state must reach the merge row: $(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "pr")]')"

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
  assert_contains "$html" 'id="pane-updates"' "the dominant attention queue must be rendered"
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
  assert_contains "$out" "fm-mission-control.v2" "the refusal should name the document it needs"
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
    (.updates[] | select(.kind == "pr") | select(.number == 12)
     | .turn == "worker" and .action == null
       and (.headline | startswith("Blocked on")))
    # The concrete thing happening belongs to the TASK; the update points at it.
    and (.tasks[] | select(.id == "busy-pr") | .activity.text | test("validation running"))
  ' >/dev/null || fail "a pull request whose lane is still running is not the captain's turn: \
$(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "pr")|{number,turn,headline}]')"

  # A question of his is his turn, and says so outright.
  printf '%s' "$out" | jq -e '
    .updates[] | select(.kind == "pr") | select(.number == 9)
    | .turn == "captain" and .action == "decide" and .headline == "Yours to decide"
  ' >/dev/null || fail "a PR held on the captain's decision must read as his turn"

  printf '%s' "$out" | jq -e '
    ([.updates[]] | all(.turn | IN("captain", "worker", "external")))
    and ([.updates[]] | all(.headline != null and .headline != ""))
    and ([.updates[]] | all(if .turn == "captain" then .action != null else .action == null end))
    # Activity is a property of the task doing the work, not of the update.
    and ([.tasks[]] | all(.activity.text != null and .activity.source != null))
  ' >/dev/null || fail "every update must carry turn, headline and a captain-only action; every task an activity"

  # A busy pane is evidence the worker is busy, not evidence about validation.
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "busy-pr") | .activity.source == "status-log"
  ' >/dev/null || fail "activity must name the evidence it came from"

  printf '%s' "$out" | jq -e '
    .counts.inbox == ([.updates[] | select(.turn == "captain")] | length)
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
    .updates[] | select(.task_id == "scout-plan") | .decisions[0]
    | .recommendation == "Option A: three steps, because the fourth is never used."
      and .recommendation_source == "hold"
      and .reasoning == null
  ' >/dev/null || fail "a stated recommendation must be carried inline: \
$(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "plan")|select(.id=="scout-plan")|.decisions]')"

  # None stated: the reasoning stands in so the row is still answerable.
  printf '%s' "$out" | jq -e '
    .updates[] | select(.task_id == "ask-only") | .decisions[0]
    | .recommendation == null and .reasoning == "Table versus DataTable."
  ' >/dev/null || fail "with no recommendation the hold reasoning must stand in: \
$(printf '%s' "$out" | jq -c '[.updates[] | select(.kind == "plan")|select(.id=="ask-only")|.decisions]')"

  printf '%s' "$out" | jq -e '
    .updates[] | select(.task_id == "scout-plan") | .recommended_count == 1
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
  assert_contains "$html" 'id="view-board"' "the board view must still ship"
  assert_contains "$html" 'id="view-inbox"' "the inbox view must ship beside it"
  assert_contains "$html" 'data-view="inbox"' "there must be a way to switch to it"
  assert_contains "$html" 'data-filter="turn"' "the inbox must filter by turn"
  assert_contains "$html" 'data-filter="kind"' "the inbox must filter by type"
  assert_contains "$html" 'data-turn="captain"' "inbox rows must be filterable by turn"
  assert_contains "$html" 'data-kind="plan"' "inbox rows must be filterable by kind"

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
    .tasks[] | select(.id == "busy-pr")
    | .attended == true and .attended_by == "worker"
      and .attended_evidence == "live-endpoint"
  ' >/dev/null || fail "a busy worker must read as being worked on: \
$(printf '%s' "$out" | jq -c '[.tasks[]|{id,attended,attended_by,attended_evidence}]')"

  # Blocked with the worker gone is the case that needs saying outright.
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "stalled-lane")
    | .attended == false and .attended_by == null
      and (.attended_evidence | IN("no-endpoint", "idle-endpoint"))
  ' >/dev/null || fail "a blocked lane with no worker must read as unattended: \
$(printf '%s' "$out" | jq -c '[.tasks[]|{id,state,attended,attended_evidence}]')"

  # Unverifiable ownership is its own answer, never guessed either way.
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "unverified-lane")
    | .attended == null and .attended_evidence == "unverified"
  ' >/dev/null || fail "unverifiable ownership must stay null, not be guessed: \
$(printf '%s' "$out" | jq -c '[.tasks[]|select(.id=="unverified-lane")]')"

  printf '%s' "$out" | jq -e '
    [.tasks[]] | all(has("attended") and has("attended_evidence"))
  ' >/dev/null || fail "every task must carry attendance, so ownership is never silent"
  pass "blocked work says whether someone is on it, or that we cannot tell"
}

test_board_shape_and_task_screen() {
  local home state html
  home=$(make_home shape)
  write_fixture "$home"
  state=$TMP_ROOT/shape-state.json
  state_for "$home" > "$state"
  html=$("$DASH" --render "$state") || fail "render failed"

  # Every link the captain follows opens in a new tab: he works from this page.
  local links newtab
  # Count occurrences, not lines: the rendered body is one long line.
  links=$(printf '%s' "$html" | grep -o '<a class="go"' | wc -l | tr -d ' ')
  newtab=$(printf '%s' "$html" | grep -o 'class="go" href=[^>]*target="_blank"' | wc -l | tr -d ' ')
  [ "$links" -gt 0 ] || fail "the inbox must offer actions to open"
  [ "$links" = "$newtab" ] || fail "every action must open in a new tab ($newtab of $links)"

  # The inline expanded activity list was explicitly rejected.
  printf '%s' "$html" | grep -q '<main id="view-board".*<details' \
    && fail "the board must not expand activity inline"
  assert_not_contains "$html" 'class="lane"' "the old lane disclosure must be gone"

  # History lives on a per-task screen instead.
  assert_contains "$html" 'id="view-task"' "there must be a per-task screen"
  assert_contains "$html" 'class="history"' "the task screen must carry a first-class history"
  assert_contains "$html" 'class="back"' "the task screen must offer a way back"

  # One task component, used by both status views.
  local cards
  cards=$(printf '%s' "$html" | grep -o '<article class="task"' | wc -l | tr -d ' ')
  [ "$cards" -gt 1 ] || fail "tasks must render through one component, got $cards"
  assert_contains "$html" 'class="pulse"' "an active task must read as live at a glance"

  # The captain's inbox refinements.
  assert_contains "$html" 'data-filter="kind"' "the inbox must filter by plan or PR"
  assert_contains "$html" 'v—' "version must render as an honest placeholder"
  printf '%s' "$html" | grep -qE '<span class="when">(just now|[0-9]+[mhd]|yesterday)</span>' \
    || fail "age must stay, in human form"
  printf '%s' "$html" | grep -q 'questions</span>' \
    && fail "the question count was dropped from the inbox"

  # Recommendations moved to the task screen rather than being lost.
  assert_contains "$html" 'Recommended:' "a recommended answer must still be readable somewhere"

  # Panels are draggable.
  assert_contains "$html" 'data-grip=' "panels must be resizable"
  pass "board leads with updates, tasks render once, history and questions live on the task screen"
}

test_empty_home_is_honest
test_updates_are_only_plans_and_prs
test_one_task_component_both_states
test_blocked_says_whether_anyone_is_on_it
test_board_shape_and_task_screen
test_turn_says_whose_move_it_is
test_decisions_carry_their_recommendation
test_inbox_view_ships_beside_the_panels
test_titles_and_links_are_real
test_decision_queue_dedupes_against_status
test_merge_queue_names_its_blockers
test_merge_queue_uses_authoritative_waits
test_promoted_scout_report_cannot_mask_pr
test_activity_feed_is_newest_first
test_completed_retention_is_disclosed
test_pr_cache_ages_and_is_local_only
test_page_is_self_contained_and_escapes_hostile_text
test_render_refuses_a_foreign_document
test_html_is_a_rendering_of_the_written_document
test_output_publish_failure_is_reported
