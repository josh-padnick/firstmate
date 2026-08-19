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
dispatch() {  # <data-dir> <args...>; sets DISPATCH_OUT and DISPATCH_RC
  local data=$1
  shift
  DISPATCH_RC=0
  DISPATCH_OUT=$(PATH="${DISPATCH_FAKEBIN:+$DISPATCH_FAKEBIN:}$PATH" \
    FM_DATA_OVERRIDE="$data" FM_REVIEW_DISPATCH_NOW=2026-08-19T10:00:00Z \
    "$DISPATCH" "$@" 2>&1) || DISPATCH_RC=$?
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
  assert_contains "$out" 'record the refusal first' \
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

test_coderabbit_is_the_default_and_owns_the_pr
test_exactly_one_owner_survives_a_second_dispatch_attempt
test_fallback_needs_a_recorded_refusal_and_prefers_waiting
test_reserve_floor_stops_auto_picks_but_not_the_captain
test_zero_credits_refuses_even_an_explicit_greptile_dispatch
test_devin_stays_in_reserve_until_quota_is_confirmed
test_ledger_is_private_and_records_every_event
test_check_flags_a_review_from_a_non_owner
test_bad_input_is_refused_before_anything_is_written
