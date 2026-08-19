#!/usr/bin/env bash
# Behavioral regressions for bin/fm-review-dispatch.sh: the exactly-one owner
# rule, the refusal-before-fallback chain, the Greptile reserve floor, the
# ledger's monthly reconcile, the terminal in-house fallback, and the
# dispatch-side consistency check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISPATCH="$ROOT/bin/fm-review-dispatch.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-dispatch)

PR_A=https://github.com/josh-padnick/firstmate/pull/101
PR_B=https://github.com/josh-padnick/firstmate/pull/102

# Each case gets its own data directory so one case's ledger cannot leak into
# the next. NOW is pinned so the billing-month arithmetic is deterministic.
new_home() {  # <name>; echoes the data directory
  local data="$TMP_ROOT/$1/data"
  mkdir -p "$data"
  printf '%s\n' "$data"
}

# Runs the helper in THIS shell (never a command substitution) so both the
# captured output and the exit status survive for the assertions.
DISPATCH_OUT=
DISPATCH_RC=0
DISPATCH_FAKEBIN=
DISPATCH_NOW=2026-08-19T10:00:00Z
dispatch() {  # <data-dir> <args...>; sets DISPATCH_OUT and DISPATCH_RC
  local data=$1
  shift
  DISPATCH_RC=0
  DISPATCH_OUT=$(PATH="${DISPATCH_FAKEBIN:+$DISPATCH_FAKEBIN:}$PATH" \
    FM_DATA_OVERRIDE="$data" FM_REVIEW_DISPATCH_NOW="$DISPATCH_NOW" \
    "$DISPATCH" "$@" 2>&1) || DISPATCH_RC=$?
}

# The same call with the clock moved, for the billing-month arithmetic.
dispatch_at() {  # <iso8601-utc> <data-dir> <args...>
  local now=$1 previous=$DISPATCH_NOW
  shift
  DISPATCH_NOW=$now
  dispatch "$@"
  DISPATCH_NOW=$previous
}

test_coderabbit_is_the_default_and_owns_the_pr() {
  local data out
  data=$(new_home default)

  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a fresh PR must get a dispatch"
  assert_contains "$out" 'service: coderabbit' \
    "the zero-cost hourly service is not the default pick"
  assert_contains "$out" '@coderabbitai review' \
    "the exact trigger comment is missing from the choice"

  dispatch "$data" record "$PR_A" coderabbit requested
  expect_code 0 "$DISPATCH_RC" "recording the first dispatch must succeed"

  # A fix round re-uses the owner rather than naming a second service.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a fix round on an owned PR must still answer"
  assert_contains "$out" 'service: coderabbit' \
    "a fix round did not re-use the recorded owner"
  assert_contains "$out" 'existing owner' \
    "the choice did not say the PR is already owned"

  pass "CodeRabbit leads by default and stays the PR's owner across fix rounds"
}

test_exactly_one_owner_survives_a_second_dispatch_attempt() {
  local data out
  data=$(new_home exactly-one)
  dispatch "$data" record "$PR_A" coderabbit requested

  dispatch "$data" choose "$PR_A" --service greptile
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "choosing a second service on an owned PR must be refused"
  assert_contains "$out" 'already owned by coderabbit' \
    "the refusal did not name the recorded owner"

  dispatch "$data" record "$PR_A" greptile requested
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "recording a second owner must be refused"
  assert_contains "$out" 'already owned by coderabbit' \
    "the ledger accepted a second review owner"

  pass "a PR keeps exactly one review owner until a refusal is recorded"
}

test_fallback_needs_a_recorded_refusal_and_prefers_waiting() {
  local data out
  data=$(new_home refusal)
  dispatch "$data" record "$PR_A" coderabbit requested

  # Silence is not refusal: the fallback stays shut until the refusal is on record.
  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "--after-refusal must refuse before the refusal is recorded"
  assert_contains "$out" "record $PR_A coderabbit refused" \
    "the refusal did not point at the ledger step that unlocks the fallback"

  dispatch "$data" record "$PR_A" coderabbit refused --note 'retry in 12 minutes'
  expect_code 0 "$DISPATCH_RC" "recording a refusal must succeed"

  # Wait beats switch: a plain choose still declines to spend a credit.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "a recorded refusal must not silently spend a credit"
  assert_contains "$out" 'wait beats switch' \
    "the refusal did not offer the wait-and-retrigger default"

  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "the fallback must open once the refusal is recorded"
  assert_contains "$out" 'service: greptile' \
    "the recorded refusal did not move ownership down the priority order"

  pass "the depletable pools open only after an explicit refusal is on record"
}

test_reserve_floor_stops_auto_picks_but_not_the_captain() {
  local data out
  data=$(new_home floor)
  # The captain relays 11 remaining, so one dispatch lands the ledger on the floor.
  dispatch "$data" reconcile greptile 11 --note 'dashboard read'
  expect_code 0 "$DISPATCH_RC" "a relayed dashboard number must be recordable"
  dispatch "$data" record "$PR_A" coderabbit refused

  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  assert_contains "$out" 'service: greptile' \
    "one credit above the floor must still auto-pick greptile"

  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" status
  out=$DISPATCH_OUT
  assert_contains "$out" 'greptile: 10 of 50 credits remaining' \
    "the ledger did not count the dispatch down from the relayed number"
  assert_contains "$out" 'captain-explicit only' \
    "status did not report that auto-picks have stopped at the floor"

  dispatch "$data" record "$PR_B" coderabbit refused
  dispatch "$data" choose "$PR_B" --after-refusal
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a dry fleet must still get a reviewer"
  assert_not_contains "$out" 'service: greptile' \
    "an auto-pick spent a credit from the reserve"
  assert_contains "$out" 'service: in-house' \
    "the terminal fallback did not take over when every pool was unavailable"

  # The floor bounds automatic picks only; the captain can still spend it.
  dispatch "$data" choose "$PR_B" --service greptile
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "an explicit captain choice must survive the floor"
  assert_contains "$out" 'service: greptile' \
    "the captain could not spend reserve credits explicitly"

  pass "auto-picks stop at the reserve floor while captain-explicit dispatch continues"
}

test_zero_credits_refuses_even_an_explicit_greptile_dispatch() {
  local data out
  data=$(new_home zero)
  dispatch "$data" reconcile greptile 0

  dispatch "$data" choose "$PR_A" --service greptile
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "a no-op dispatch under the \$0 cap must be refused"
  assert_contains "$out" 'flex cap' \
    "the refusal did not explain why the review would produce nothing"
  assert_contains "$out" 'reconcile' \
    "the refusal did not offer the reconcile path for a disagreeing dashboard"

  # Greptile never held this PR, so the refusal must not send the operator off
  # to record a release that did not happen.
  assert_not_contains "$out" 'exhausted' \
    "the refusal named a release for a PR the service was never dispatched to"
  dispatch "$data" check "$PR_A" --ledger-only
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "an unowned PR must still fail the ownership check"
  assert_contains "$out" 'owner: none recorded' \
    "the refused dispatch left a release row on a PR that was never dispatched"

  pass "a dry pool under the \$0 flex cap is refused rather than dispatched into a skip"
}

test_devin_stays_in_reserve_until_quota_is_confirmed() {
  local data out
  data=$(new_home devin)
  dispatch "$data" reconcile greptile 0
  dispatch "$data" record "$PR_A" coderabbit refused

  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  assert_not_contains "$out" 'service: devin' \
    "devin was auto-picked without a confirmed dashboard quota"

  dispatch "$data" choose "$PR_A" --after-refusal --devin-quota-confirmed
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a confirmed devin quota must open the reserve"
  assert_contains "$out" 'service: devin' \
    "a confirmed quota did not reach the reserve service"
  assert_contains "$out" '/devin review' \
    "the devin trigger comment is missing"

  pass "Devin is reached only on explicit choice or a confirmed dashboard quota"
}

test_ledger_is_private_and_records_every_event() {
  local data ledger perms
  data=$(new_home ledger)
  dispatch "$data" record "$PR_A" coderabbit requested --note 'first round'
  dispatch "$data" record "$PR_A" coderabbit reviewed
  ledger="$data/review-dispatch/ledger.tsv"

  assert_present "$ledger" "the ledger was not created"
  assert_grep "$PR_A"$'\t'"coderabbit"$'\t'"requested" "$ledger" \
    "the dispatch row is missing from the ledger"
  assert_grep "$PR_A"$'\t'"coderabbit"$'\t'"reviewed" "$ledger" \
    "the review row is missing from the ledger"
  assert_grep 'first round' "$ledger" "the note was dropped"

  perms=$(stat -f %Lp "$ledger" 2>/dev/null || stat -c %a "$ledger" 2>/dev/null)
  [ "$perms" = 600 ] || fail "the ledger must stay captain-private (mode $perms)"

  pass "the ledger records each event privately with its note"
}

test_check_flags_a_review_from_a_non_owner() {
  local data out fakebin
  data=$(new_home check)
  fakebin=$(fm_fakebin "$TMP_ROOT/check")
  dispatch "$data" record "$PR_A" coderabbit requested

  # Evidence lives in PR comments, so the check reads comment authors. First a
  # PR carrying only the owner's comment.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'coderabbitai\n'
SH
  chmod +x "$fakebin/gh"
  DISPATCH_FAKEBIN=$fakebin
  dispatch "$data" check "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a PR reviewed by its recorded owner must pass the check"
  assert_contains "$out" 'verdict: consistent' \
    "the owner's own review was not accepted as consistent"

  # Then the same PR also carrying a second service's comment: a migration leak.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'coderabbitai\ngreptile-apps\n'
SH
  chmod +x "$fakebin/gh"
  dispatch "$data" check "$PR_A"
  out=$DISPATCH_OUT
  DISPATCH_FAKEBIN=
  expect_code 2 "$DISPATCH_RC" "a second service's review must not pass the check"
  assert_contains "$out" 'leak: greptile' \
    "the check did not name the service that reviewed outside its ownership"

  pass "the consistency check accepts comment evidence from the owner and flags any other"
}

test_a_fix_round_carries_the_same_credit_rules_as_any_dispatch() {
  local data out
  data=$(new_home fix-round)
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested

  # A fix round on a greptile-owned PR re-uses the owner, and re-triggering a
  # paid reviewer is a dispatch like any other: it costs a credit and has a
  # ledger step.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a fix round on an owned PR must still answer"
  assert_contains "$out" 'service: greptile' \
    "a fix round did not re-use the recorded owner"
  assert_contains "$out" 'cost: 1 credit' \
    "a paid fix-round re-review was priced as free"
  assert_contains "$out" "record $PR_A greptile requested" \
    "the fix round did not print the step that puts the re-trigger on the ledger"

  # Following that step is what makes the second credit countable.
  dispatch "$data" record "$PR_A" greptile requested
  expect_code 0 "$DISPATCH_RC" "recording a fix-round re-trigger must be accepted"
  dispatch "$data" status
  out=$DISPATCH_OUT
  assert_contains "$out" 'greptile: 48 of 50 credits remaining' \
    "the recorded fix-round re-trigger did not count against the month"

  # CodeRabbit's window costs nothing, so its fix rounds stay free - checked
  # with the ledger sitting on the reserve floor, where a guard wrongly applied
  # to a coderabbit owner would have something to warn about.
  dispatch "$data" reconcile greptile 10
  dispatch "$data" record "$PR_B" coderabbit requested
  dispatch "$data" choose "$PR_B"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a coderabbit fix round must still answer"
  assert_contains "$out" 'service: coderabbit' \
    "a coderabbit fix round did not re-use the recorded owner"
  assert_not_contains "$out" 'cost:' \
    "the zero-cost hourly service was priced on a fix round"
  assert_not_contains "$out" 'reserve floor' \
    "a free fix round warned about the depletable reserve"

  pass "a fix round is priced and recorded exactly like the dispatch it repeats"
}

test_a_fix_round_cannot_dispatch_greptile_at_zero_credits() {
  local data out
  data=$(new_home fix-round-zero)
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" reconcile greptile 0

  # The $0 flex cap has no fix-round exception: the review would be skipped.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "a fix round at zero credits must be refused like any other dispatch"
  assert_contains "$out" 'flex cap' \
    "the refusal did not explain why the re-review would produce nothing"
  assert_not_contains "$out" 'trigger: @greptileai' \
    "the refused fix round still handed over a trigger comment"

  # And a fix round at the floor warns before it spends the reserve.
  dispatch "$data" reconcile greptile 10
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a fix round at the floor must still be allowed"
  assert_contains "$out" 'reserve floor' \
    "a fix round spent from the reserve without warning"

  pass "a fix round carries the zero-credit refusal and the reserve-floor warning"
}

test_an_exhausted_pool_releases_the_pr_to_the_in_house_review() {
  local data out
  data=$(new_home exhausted)
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" reconcile greptile 0

  # A fix round with no credits left is refused, and the refusal must name the
  # command that records what actually happened.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "a fix round at zero credits must be refused"
  assert_contains "$out" "record $PR_A greptile exhausted" \
    "the refusal named no supported way forward"

  dispatch "$data" record "$PR_A" greptile exhausted
  expect_code 0 "$DISPATCH_RC" "recording an exhausted pool must be accepted"
  dispatch "$data" check "$PR_A" --ledger-only
  out=$DISPATCH_OUT
  assert_contains "$out" 'exhausted: greptile' \
    "the exhausted pool did not release its ownership of the PR"

  # A dry fleet gets our own review, and does not have to claim a refusal it
  # never received to get there.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a dry fleet must still get a reviewer"
  assert_contains "$out" 'service: in-house' \
    "the terminal fallback did not take over once every pool was recorded dry"
  assert_contains "$out" 'doctrine:' \
    "the in-house choice did not carry its review doctrine"

  pass "an exhausted pool releases the PR and the in-house review takes it over"
}

test_an_exhausted_pool_refunds_nothing() {
  local data out
  data=$(new_home exhausted-credits)
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" status
  out=$DISPATCH_OUT
  assert_contains "$out" 'greptile: 49 of 50 credits remaining' \
    "the greptile dispatch did not count against the month"

  # Exhaustion says a later dispatch was never made; it says nothing about the
  # credit the earlier one already spent.
  dispatch "$data" record "$PR_A" greptile exhausted
  expect_code 0 "$DISPATCH_RC" "recording an exhausted pool must be accepted"
  dispatch "$data" status
  out=$DISPATCH_OUT
  assert_contains "$out" 'greptile: 49 of 50 credits remaining' \
    "an exhausted row refunded a credit that was really spent"

  pass "recording an exhausted pool never refunds an already-spent credit"
}

test_check_accepts_the_comment_a_released_owner_left_behind() {
  local data out fakebin
  data=$(new_home check-exhausted)
  fakebin=$(fm_fakebin "$TMP_ROOT/check-exhausted")

  # The path the exhausted event exists for: coderabbit refuses, greptile
  # reviews round one, its pool runs dry, and the in-house review takes over.
  dispatch "$data" record "$PR_A" coderabbit requested
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" record "$PR_A" greptile reviewed
  dispatch "$data" record "$PR_A" greptile exhausted
  dispatch "$data" record "$PR_A" in-house requested

  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'coderabbitai\ngreptile-apps\n'
SH
  chmod +x "$fakebin/gh"
  DISPATCH_FAKEBIN=$fakebin
  dispatch "$data" check "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a released owner's own review must not read as a leak"
  assert_contains "$out" 'verdict: consistent' \
    "the check refused the release path the ledger records in full"

  # A service with no recorded reason to be on this PR is still a leak.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'coderabbitai\ngreptile-apps\ndevin-ai-integration\n'
SH
  chmod +x "$fakebin/gh"
  dispatch "$data" check "$PR_A"
  out=$DISPATCH_OUT
  DISPATCH_FAKEBIN=
  expect_code 2 "$DISPATCH_RC" "an unexplained third service must still fail the check"
  assert_contains "$out" 'leak: devin' \
    "the check did not name the service the ledger explains nothing about"

  pass "a refused or exhausted release explains that service's comment on the PR"
}

test_the_in_house_reason_states_only_what_the_ledger_records() {
  local data out
  data=$(new_home in-house-reason)
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile refused

  # Devin has no row at all here: the reason must not claim one.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a dry fleet must still get a reviewer"
  assert_contains "$out" 'service: in-house' \
    "the terminal fallback did not take over"
  assert_contains "$out" 'devin is unreachable without --devin-quota-confirmed' \
    "the reason did not name why the unrecorded reserve was skipped"
  assert_not_contains "$out" 'every third-party service is recorded' \
    "the reason claimed a devin event the ledger never recorded"

  # Once devin is genuinely recorded, the ledger does say every service is out.
  dispatch "$data" record "$PR_A" devin refused
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "a fully recorded dry fleet must still get a reviewer"
  assert_contains "$out" 'every third-party service is recorded as refused or exhausted' \
    "the reason did not report the state the ledger actually holds"

  pass "the in-house choice reports the ledger's own state and nothing more"
}

# One ledger per case, so a case cannot inherit another's rows. Each row is
# "<iso8601-utc>,<service>,<event>" - or "<iso8601-utc>,reconcile,<number>" for
# a relayed dashboard baseline - and <expected> is the credits the ledger must
# report remaining when `status` runs at <status-at>.
charge_case() {  # <name> <expected> <status-at> <row>...
  local name=$1 expected=$2 at=$3 data row ts field service event
  shift 3
  data=$(new_home "charge-$name")
  for row in "$@"; do
    IFS=, read -r ts service field <<< "$row"
    if [ "$service" = reconcile ]; then
      dispatch_at "$ts" "$data" reconcile greptile "$field"
    else
      event=$field
      dispatch_at "$ts" "$data" record "$PR_A" "$service" "$event"
    fi
    expect_code 0 "$DISPATCH_RC" "$name: the ledger rejected the row '$row'"
  done
  dispatch_at "$at" "$data" status
  assert_contains "$DISPATCH_OUT" "greptile: $expected of 50 credits remaining" \
    "$name: the ledger charged the wrong number of greptile credits"
}

test_the_greptile_charge_table() {
  local aug=2026-08-19T10:00:00Z

  # Per PR the ledger walks its rows in order: a review answers the most recent
  # unanswered standing dispatch or charges a credit of its own, and a refusal
  # cancels the most recent unanswered standing dispatch. What is charged is
  # the self-charging reviews plus the dispatches still standing. Every row
  # below is a case this contract has been ruled on, kept together so the whole
  # of it reads at a glance.
  charge_case plain-dispatch 49 "$aug" \
    "$aug,greptile,requested"
  charge_case refunded-dispatch 50 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,refused"
  charge_case retry-path 49 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,refused" "$aug,greptile,requested"
  charge_case true-leak 49 "$aug" \
    "$aug,greptile,reviewed"
  charge_case same-pr-re-review 48 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,reviewed" "$aug,greptile,reviewed"
  charge_case reviewed-then-refused 49 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,reviewed" "$aug,greptile,refused"
  charge_case refused-then-reviewed 49 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,refused" "$aug,greptile,reviewed"
  charge_case refunded-then-re-reviewed 48 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,refused" "$aug,greptile,requested" \
    "$aug,greptile,reviewed" "$aug,greptile,reviewed"
  charge_case two-dispatches-two-reviews 48 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,reviewed" \
    "$aug,greptile,requested" "$aug,greptile,reviewed"

  # A delivered review answers its own dispatch, so the refusal that follows it
  # has nothing left to refund and the retry after it is a second credit.
  charge_case reviewed-refused-retried 48 "$aug" \
    "$aug,greptile,requested" "$aug,greptile,reviewed" \
    "$aug,greptile,refused" "$aug,greptile,requested"
  charge_case reviewed-refused-retried-july 49 2026-07-31T11:00:00Z \
    "2026-07-20T10:00:00Z,greptile,requested" "2026-07-21T10:00:00Z,greptile,reviewed" \
    "2026-07-22T10:00:00Z,greptile,refused" "2026-08-03T10:00:00Z,greptile,requested"
  charge_case reviewed-refused-retried-august 49 2026-08-04T11:00:00Z \
    "2026-07-20T10:00:00Z,greptile,requested" "2026-07-21T10:00:00Z,greptile,reviewed" \
    "2026-07-22T10:00:00Z,greptile,refused" "2026-08-03T10:00:00Z,greptile,requested"

  # A credit is charged to the window its own dispatch was recorded in. July
  # pays for the dispatch; August, where only the review lands, pays nothing.
  charge_case cross-window-july 49 2026-07-30T11:00:00Z \
    "2026-07-30T10:00:00Z,greptile,requested" "2026-08-02T10:00:00Z,greptile,reviewed"
  charge_case cross-window-august 50 2026-08-02T11:00:00Z \
    "2026-07-30T10:00:00Z,greptile,requested" "2026-08-02T10:00:00Z,greptile,reviewed"

  # A review that arrived before this PR was ever dispatched is a credit of its
  # own: the later dispatch cannot answer for it.
  charge_case leaked-then-dispatched 48 "$aug" \
    "$aug,greptile,reviewed" "$aug,greptile,requested"

  # A refusal answers the dispatch it followed, so the credit stays charged to
  # the window that really spent it - whether the surviving dispatch is the
  # earlier one or the retry that came after the refund.
  charge_case cross-window-refusal-july 49 2026-07-31T11:00:00Z \
    "2026-07-30T10:00:00Z,greptile,requested" "2026-08-10T10:00:00Z,greptile,requested" \
    "2026-08-11T10:00:00Z,greptile,refused"
  charge_case cross-window-refusal-august 50 2026-08-12T11:00:00Z \
    "2026-07-30T10:00:00Z,greptile,requested" "2026-08-10T10:00:00Z,greptile,requested" \
    "2026-08-11T10:00:00Z,greptile,refused"
  charge_case cross-window-retry-july 50 2026-07-31T11:00:00Z \
    "2026-07-30T10:00:00Z,greptile,requested" "2026-07-30T11:00:00Z,greptile,refused" \
    "2026-08-03T10:00:00Z,greptile,requested"
  charge_case cross-window-retry-august 49 2026-08-04T11:00:00Z \
    "2026-07-30T10:00:00Z,greptile,requested" "2026-07-30T11:00:00Z,greptile,refused" \
    "2026-08-03T10:00:00Z,greptile,requested"

  # A relayed dashboard number already reflects the dispatches before it, so a
  # review recorded after the baseline does not count forward a second time.
  charge_case reconcile-baseline 45 2026-08-07T11:00:00Z \
    "2026-08-05T10:00:00Z,greptile,requested" "2026-08-06T10:00:00Z,reconcile,45" \
    "2026-08-07T10:00:00Z,greptile,reviewed"
  charge_case reconcile-baseline-retry 44 2026-08-08T11:00:00Z \
    "2026-08-05T10:00:00Z,greptile,requested" "2026-08-05T11:00:00Z,greptile,refused" \
    "2026-08-06T10:00:00Z,reconcile,45" "2026-08-07T10:00:00Z,greptile,requested"

  pass "the greptile ledger charges each credit once, in the window that owns it"
}

test_record_warns_when_a_review_lands_on_a_pr_it_does_not_own() {
  local data out
  data=$(new_home leaked-review)
  dispatch "$data" record "$PR_A" coderabbit requested

  dispatch "$data" record "$PR_A" greptile reviewed
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "recording a leaked review must still succeed"
  assert_contains "$out" 'recording the leak' \
    "the leak was not surfaced at the record boundary"

  pass "recording a review from a non-owner surfaces the leak as it is written"
}

test_a_release_step_names_the_event_that_actually_happened() {
  local data out
  data=$(new_home release-step)
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" reconcile greptile 0

  # Greptile owns this PR and its pool is dry, so every path that hands the PR
  # on must name the exhaustion that happened - never a refusal it never made.
  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "an owned PR must refuse a second dispatch"
  assert_contains "$out" "record $PR_A greptile exhausted" \
    "the transfer named no release for a credit-starved owner"
  assert_contains "$out" "record $PR_A greptile refused" \
    "the transfer named no release for a service that declined while the pool was dry"

  dispatch "$data" choose "$PR_A" --service in-house
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "dispatching a second service must be refused"
  assert_contains "$out" "record $PR_A greptile exhausted" \
    "the explicit-service refusal named no release for a credit-starved owner"

  dispatch "$data" record "$PR_A" in-house requested
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "recording a second owner must be refused"
  assert_contains "$out" "record $PR_A greptile exhausted" \
    "the record refusal named no release for a credit-starved owner"

  # With credits on hand there is no exhaustion to record, so the same paths
  # name the refusal instead.
  dispatch "$data" reconcile greptile 40
  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  assert_contains "$out" "record $PR_A greptile refused" \
    "a pool with credits left was released as exhausted"

  pass "every printed release names the event the ledger would truthfully record"
}

test_status_reports_a_pending_fix_round_as_awaiting_review() {
  local data out
  data=$(new_home open-owners)
  dispatch "$data" record "$PR_A" coderabbit requested
  dispatch "$data" record "$PR_A" coderabbit reviewed
  dispatch "$data" status
  out=$DISPATCH_OUT
  assert_contains "$out" "$PR_A coderabbit (review recorded)" \
    "a delivered review was not reported as recorded"

  # A fix round re-dispatches the same owner, and that dispatch is waiting.
  dispatch "$data" record "$PR_A" coderabbit requested
  dispatch "$data" status
  out=$DISPATCH_OUT
  assert_contains "$out" "$PR_A coderabbit (awaiting review)" \
    "a re-dispatched PR was reported as already reviewed"

  pass "the open-owners list reports the newest dispatch rather than any past review"
}

test_a_dry_standing_owner_is_offered_both_releases() {
  local data out
  data=$(new_home dry-owner)
  dispatch "$data" reconcile greptile 1
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested
  dispatch "$data" status
  assert_contains "$DISPATCH_OUT" 'greptile: 0 of 50 credits remaining' \
    "the standing dispatch did not spend the last credit"

  # The ledger reads zero and a dispatch is standing, so either release could
  # be the true one. The tool states the balance and names both rather than
  # guessing which event the operator saw.
  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "an owned PR must refuse a second dispatch"
  assert_contains "$out" "record $PR_A greptile refused if greptile declined" \
    "the release named no refusal for a service that may have declined"
  assert_contains "$out" "record $PR_A greptile exhausted if no dispatch was made" \
    "the release named no exhaustion for a pool the ledger shows dry"

  # Recording what really happened returns the credit the cancelled dispatch
  # never spent - the outcome a guessed `exhausted` row would have forfeited.
  dispatch "$data" record "$PR_A" greptile refused
  expect_code 0 "$DISPATCH_RC" "recording the refusal that happened must succeed"
  dispatch "$data" status
  assert_contains "$DISPATCH_OUT" 'greptile: 1 of 50 credits remaining' \
    "the refusal did not return the credit the guessed exhaustion would have kept"

  pass "a dry ledger with a standing owner names both releases instead of guessing"
}

test_bad_input_is_refused_before_anything_is_written() {
  local data
  data=$(new_home input)

  dispatch "$data" choose 'https://example.com/not/a/pr'
  expect_code 1 "$DISPATCH_RC" "a non-PR URL must be refused"
  dispatch "$data" record "$PR_A" macroscope requested
  expect_code 1 "$DISPATCH_RC" "an unknown service must be refused"
  dispatch "$data" record "$PR_A" coderabbit merged
  expect_code 1 "$DISPATCH_RC" "an unknown event must be refused"
  dispatch "$data" reconcile greptile twelve
  expect_code 1 "$DISPATCH_RC" "a non-numeric relayed count must be refused"
  assert_absent "$data/review-dispatch/ledger.tsv" \
    "a refused request still wrote to the ledger"

  pass "invalid input is refused before any ledger row is written"
}

test_the_retry_after_a_refusal_is_an_executable_path() {
  local data out
  data=$(new_home retry)
  dispatch "$data" record "$PR_A" coderabbit requested
  dispatch "$data" record "$PR_A" coderabbit refused --note 'retry in 12 minutes'

  # The wait-beats-switch refusal must name a command that actually works.
  dispatch "$data" choose "$PR_A"
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "a plain choose after a refusal must still decline to switch"
  assert_contains "$out" "choose $PR_A --service coderabbit" \
    "the refusal did not name the re-trigger command it recommends"

  dispatch "$data" choose "$PR_A" --service coderabbit
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "re-triggering the refusing service must be a supported choice"
  assert_contains "$out" 'service: coderabbit' \
    "the retry path did not name the service being re-triggered"
  assert_contains "$out" "record $PR_A coderabbit requested" \
    "the retry path did not print the ledger step that restores ownership"

  # Following that printed step must put ownership back, so the depletable
  # pools stay shut while the re-triggered review is in flight.
  dispatch "$data" record "$PR_A" coderabbit requested
  expect_code 0 "$DISPATCH_RC" "the printed record step must be accepted"
  dispatch "$data" choose "$PR_A" --after-refusal
  out=$DISPATCH_OUT
  expect_code 2 "$DISPATCH_RC" "a re-triggered owner must block a second dispatch"
  assert_contains "$out" 'still owned by coderabbit' \
    "the re-trigger did not re-establish ownership of the PR"

  pass "the re-trigger the refusal recommends is a supported choose that restores ownership"
}

test_check_accepts_the_comment_a_refusal_left_behind() {
  local data out fakebin
  data=$(new_home check-refused)
  fakebin=$(fm_fakebin "$TMP_ROOT/check-refused")

  # The design's own fallback path: coderabbit refuses (in a PR comment) and
  # greptile takes the PR over.
  dispatch "$data" record "$PR_A" coderabbit requested
  dispatch "$data" record "$PR_A" coderabbit refused
  dispatch "$data" record "$PR_A" greptile requested

  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'coderabbitai\ngreptile-apps\n'
SH
  chmod +x "$fakebin/gh"
  DISPATCH_FAKEBIN=$fakebin
  dispatch "$data" check "$PR_A"
  out=$DISPATCH_OUT
  expect_code 0 "$DISPATCH_RC" "the refused predecessor's own comment must not read as a leak"
  assert_contains "$out" 'verdict: consistent' \
    "the check refused the fallback path the ledger is designed to record"

  # A service that neither owns the PR nor refused it is still a leak.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'coderabbitai\ngreptile-apps\ndevin-ai-integration\n'
SH
  chmod +x "$fakebin/gh"
  dispatch "$data" check "$PR_A"
  out=$DISPATCH_OUT
  DISPATCH_FAKEBIN=
  expect_code 2 "$DISPATCH_RC" "an unexplained third service must still fail the check"
  assert_contains "$out" 'leak: devin' \
    "the check did not name the service with no recorded reason to be here"

  pass "a recorded refusal explains that service's comment while other leaks still fail"
}

test_the_ledger_directory_is_private() {
  local data perms
  data=$(new_home ledger-dir)
  dispatch "$data" record "$PR_A" coderabbit requested

  assert_present "$data/review-dispatch" "the ledger directory was not created"
  perms=$(stat -f %Lp "$data/review-dispatch" 2>/dev/null || stat -c %a "$data/review-dispatch" 2>/dev/null)
  [ "$perms" = 700 ] || fail "the ledger directory must stay captain-private (mode $perms)"

  pass "the ledger directory is created captain-private"
}

test_coderabbit_is_the_default_and_owns_the_pr
test_exactly_one_owner_survives_a_second_dispatch_attempt
test_fallback_needs_a_recorded_refusal_and_prefers_waiting
test_reserve_floor_stops_auto_picks_but_not_the_captain
test_zero_credits_refuses_even_an_explicit_greptile_dispatch
test_devin_stays_in_reserve_until_quota_is_confirmed
test_ledger_is_private_and_records_every_event
test_check_flags_a_review_from_a_non_owner
test_check_accepts_the_comment_a_refusal_left_behind
test_the_retry_after_a_refusal_is_an_executable_path
test_the_ledger_directory_is_private
test_the_greptile_charge_table
test_record_warns_when_a_review_lands_on_a_pr_it_does_not_own
test_a_fix_round_carries_the_same_credit_rules_as_any_dispatch
test_a_fix_round_cannot_dispatch_greptile_at_zero_credits
test_an_exhausted_pool_releases_the_pr_to_the_in_house_review
test_an_exhausted_pool_refunds_nothing
test_check_accepts_the_comment_a_released_owner_left_behind
test_the_in_house_reason_states_only_what_the_ledger_records
test_a_release_step_names_the_event_that_actually_happened
test_status_reports_a_pending_fix_round_as_awaiting_review
test_a_dry_standing_owner_is_offered_both_releases
test_bad_input_is_refused_before_anything_is_written
