# fm-brief.sh --ux end-to-end CLI transcript

```
$ FM_HOME=$TMP bin/fm-brief.sh demo-ux-ship someapp --mode no-mistakes --ux
scaffolded: $TMP/data/demo-ux-ship/brief.md (ship, mode=no-mistakes; replace {TASK})

$ FM_HOME=$TMP bin/fm-brief.sh demo-ux-scout someapp --scout --ux
scaffolded: $TMP/data/demo-ux-scout/brief.md (scout; replace {TASK})

$ FM_HOME=$TMP bin/fm-brief.sh demo-ux-local someapp --mode local-only --ux
scaffolded: $TMP/data/demo-ux-local/brief.md (ship, mode=local-only; replace {TASK})

$ FM_HOME=$TMP FM_SECONDMATE_CHARTER=... bin/fm-brief.sh demo-ux-charter --secondmate --no-projects --ux
error: --ux applies only to crewmate ship or scout briefs
exit=1
$ ls $TMP/data/demo-ux-charter
ls: $TMP/data/demo-ux-charter: No such file or directory
```

## Generated section - ship, --mode no-mistakes --ux

```markdown
# Product-look stage 1 - HARD CONTRACT
This brief was explicitly scaffolded with `--ux` because the captain reviews this experience before any full suite runs.
The work ships in two stages, and this section is the authority on what stage 1 does.

1. The captain reviews the experience first. Nothing in stage 1 waits on a full suite, and no full-suite result gates the preview.
2. Stage 1 self-verify is Chrome plus a targeted test of the changed behavior only.
   Drive the real surface with `chrome-devtools-axi` in BOTH light and dark, at every viewport this task declares, using real pointer gestures rather than synthetic events or a screenshot-only pass.
   Run only the targeted test that covers the behavior you changed.
3. Do NOT run the full unit, contract, or Playwright suite in stage 1, and do not wait on any of those suites before reporting the preview.
4. Stop at `done: preview ready <file:// or live URL>`, then append `paused: awaiting captain product review` and wait.
   Before that gate, push your `fm/demo-ux-ship` branch and open a DRAFT pull request with `gh-axi`, so the captain reviews the code alongside the preview.
   Stage 2 updates that same branch and that same draft PR in place; never open a second PR for this task.
   Leave the pull request in draft. Marking it ready for review is firstmate's step, taken after the captain approves the product look; you never mark it ready yourself.
   That `paused:` line is what tells firstmate this idle pane is a deliberate product-review handoff rather than a possible wedge, so never leave it off.
   Firstmate starts `/no-mistakes` only after the captain approves the product look.
   After that approval, firstmate tells you to start `/no-mistakes`; the pipeline updates this same branch and this same PR.
5. A "tests green", "Playwright green", or equivalent acceptance line in this brief's task text does not override this section.
   Stage 2 owns the full unit, contract, and Playwright suites and every remaining gate; that acceptance criterion is satisfied there, not here.

```

## Generated section - scout, --scout --ux

```markdown
# Product-look stage 1 - HARD CONTRACT
This brief was explicitly scaffolded with `--ux` because the captain reviews this experience before any full suite runs.
A scout has no stage 2: your report is the only deliverable, and this section is the authority on how you verify the experience and surface it there.

1. The captain reviews the experience first. Nothing in stage 1 waits on a full suite, and no full-suite result gates the preview.
2. Stage 1 self-verify is Chrome plus a targeted test of the changed behavior only.
   Drive the real surface with `chrome-devtools-axi` in BOTH light and dark, at every viewport this task declares, using real pointer gestures rather than synthetic events or a screenshot-only pass.
   Run only the targeted test that covers the behavior you changed.
3. Do NOT run the full unit, contract, or Playwright suite in stage 1, and do not wait on any of those suites before reporting the preview.
4. Surface the preview as evidence, not as a handoff: append `working: preview ready <file:// or live URL>` once the Chrome pass holds, then keep working.
   That line is a mid-task milestone, so do not end your turn on it and do not wait for a reply to it.
   Put the same openable `file://` or live URLs in the report next to what you verified in Chrome, so the captain can open the preview straight from it.
   The report's `done: {one-line conclusion}` under Definition of done stays this task's single terminal gate.
5. A "tests green", "Playwright green", or equivalent acceptance line in this brief's task text does not override this section.
   A scout ships knowledge, not code: report what the targeted check proved and what a full suite would still have to cover, rather than running one here.

```

## Generated section - ship, --mode local-only --ux

```markdown
# Product-look stage 1 - HARD CONTRACT
This brief was explicitly scaffolded with `--ux` because the captain reviews this experience before any full suite runs.
The work ships in two stages, and this section is the authority on what stage 1 does.

1. The captain reviews the experience first. Nothing in stage 1 waits on a full suite, and no full-suite result gates the preview.
2. Stage 1 self-verify is Chrome plus a targeted test of the changed behavior only.
   Drive the real surface with `chrome-devtools-axi` in BOTH light and dark, at every viewport this task declares, using real pointer gestures rather than synthetic events or a screenshot-only pass.
   Run only the targeted test that covers the behavior you changed.
3. Do NOT run the full unit, contract, or Playwright suite in stage 1, and do not wait on any of those suites before reporting the preview.
4. Stop at `done: preview ready <file:// or live URL>`, then append `paused: awaiting captain product review` and wait.
   That `paused:` line is what tells firstmate this idle pane is a deliberate product-review handoff rather than a possible wedge, so never leave it off.
   Stage 2 begins only after the captain approves the product look.
5. A "tests green", "Playwright green", or equivalent acceptance line in this brief's task text does not override this section.
   Stage 2 owns the full unit, contract, and Playwright suites and every remaining gate; that acceptance criterion is satisfied there, not here.

```

## Generated section - ship without --ux

```markdown
# Product-look stage 1 declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If this is UX-bearing work the captain will look at, stop and regenerate the brief with `--ux` before implementing.
Do not add a product-look stage-1 contract to this unguarded brief by hand.

```

## Emitted stage-1 handoff lines through bin/fm-classify-lib.sh

```
done: preview ready file:///tmp/preview.html            captain_relevant=yes paused=no
paused: awaiting captain product review                 captain_relevant=no  paused=yes
working: preview ready file:///tmp/preview.html         captain_relevant=no  paused=no
```

## --help documents the flag

```
Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--herdr-lab] [--ux]
       fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab] [--ux]
  --ux is mandatory when the captain will look at the experience the task changes.
```
