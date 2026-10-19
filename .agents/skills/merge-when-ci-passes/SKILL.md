---
name: merge-when-ci-passes
description: Monitor a GitHub pull request, repair CI failures caused by its current changes, push verified fixes, and squash-merge the exact green head. Use when the user asks to watch CI, fix failures, and merge once checks pass.
---

# Merge When CI Passes

Run one local loop: **observe -> diagnose -> repair -> report -> repeat -> merge**. Keep a repair ledger so every pushed change is visible in the final report.

## Authority boundary

Invoking this skill authorizes you to:

- inspect the selected pull request, CI state, and failed logs;
- repair failures clearly caused by the pull request and within its stated intent;
- run focused verification, stage exact files, create conventional commits, and push them to the pull request branch;
- rerun failed jobs once when evidence points to infrastructure or flakiness;
- squash-merge the exact green head and synchronize the local target branch.

It does not authorize changing product intent, public contracts, schemas or migrations, security policy, dependencies, or unrelated code. It also does not authorize broad refactors, force-pushes, admin bypasses, or branch deletion. Stop and ask before any such change.

Preserve unrelated work. Never stage with `git add -A` or `git add .`. If the pull request branch is not safely writable from the current checkout, report the blocker instead of repairing it.

## 1. Resolve the pull request

1. Use the pull request number or URL supplied by the user. Otherwise resolve the pull request for the current branch with `gh pr view`.
2. Read at least `url`, `state`, `isDraft`, `baseRefName`, `headRefName`, and `headRefOid`.
3. Require an open, non-draft pull request. Record its URL, target branch, initial head SHA, and current head SHA.
4. Before editing, verify that the checked-out local branch is the pull request head branch, has the expected remote, and can be pushed without rewriting history.
5. Start an in-memory repair ledger. Do not create a repository file for it.

Complete this step when one eligible pull request and its exact head SHA are known.

## 2. Hold the green gate

Keep the loop inside the current task. Poll `gh pr checks <pr> --json bucket,link,name,state,workflow` at a sensible interval. Tell the user only when the status materially changes, a repair begins, a commit is pushed, or input is required.

Do not create or schedule an automation, heartbeat, cron job, reminder, recurring task, separate task, thread, or background handoff.

The gate is green only when:

- at least one check is reported;
- every check is terminal;
- every bucket is `pass` or `skipping`.

When no check is reported, read `.github/workflows/`. If no workflow runs on `pull_request` or `push` for this branch, the repository has no automatic CI. Skip the gate and go to step 4. Do not dispatch a manual workflow to create checks. The pull request's own verification section is the evidence. Say in the report that no CI ran. If a workflow should have triggered, keep waiting for its checks.

Treat `pending`, `fail`, and `cancel` as a closed gate. If the pull request head changes, record whether it changed locally or externally, update the current head, and restart the gate. Never carry green results from an older head forward.

Complete this step when all checks for the pull request's current head satisfy the green gate.

## 3. Repair a closed gate

When a check fails or is cancelled:

1. Resolve the workflow run from the check link and inspect failed-step logs with `gh run view <run-id> --log-failed`. Read broader logs only when the failed-step output is insufficient.
2. Classify the failure as one of:
   - **PR-caused:** the pull request introduced the failure and a repair fits its stated intent;
   - **flaky or infrastructure:** the code is not the likely cause;
   - **base failure:** the target branch fails independently of this pull request;
   - **ambiguous or out of scope:** the evidence is insufficient or the required change crosses the authority boundary.
3. Before editing, send a concise update naming the failed check, evidence-backed root cause, intended repair, and expected files.
4. For a PR-caused failure:
   - reproduce it locally with the closest focused command when possible;
   - fix the root cause, not only the reported symptom;
   - inspect the complete diff and verify only intended files changed;
   - run the smallest relevant checks, including a regression test when behavior was wrong;
   - stage exact paths, create a conventional commit, and push the current branch normally;
   - re-read the remote pull request head and require it to equal the pushed commit;
   - immediately report the failed checks, root cause, changed files, local verification, commit SHA, and new remote head;
   - append the same receipt to the repair ledger, then restart the green gate.
5. For a flaky or infrastructure failure, make no code change. Rerun failed jobs once with `gh run rerun <run-id> --failed`, record the rerun in the ledger, and restart the gate. If it fails again, report the external blocker.
6. For a base failure, do not hide it with a pull request workaround. Report the evidence and stop unless the repair is also clearly required by this pull request.
7. For an ambiguous or out-of-scope failure, show the evidence and ask the user before editing or pushing.

Never push speculative changes. A passing local check is evidence for the repair, not permission to broaden its scope.

## 4. Squash-merge the tested head

1. Re-read the pull request and its checks immediately before merging.
2. Restart the green gate if `headRefOid` changed.
3. Require the pull request to remain open, non-draft, and mergeable under normal repository protections.
4. Briefly tell the user which exact green head is about to merge and how many repair commits this loop pushed.
5. Run `gh pr merge <pr> --squash --match-head-commit <head-sha>`. Use neither admin bypass nor branch deletion unless the user explicitly requests it.
6. Verify that GitHub reports the pull request as merged and capture the merge commit.

Complete this step only when GitHub confirms that the tested head was squash-merged into the recorded target branch.

## 5. Synchronize the local target branch

Perform this step by default. Skip it when the user asks to leave the checkout unchanged or postpone synchronization.

1. Inspect the worktree before switching branches. Preserve local changes; if they make switching unsafe, report the synchronization blocker instead of stashing or discarding them.
2. Switch to the pull request target branch.
3. Pull its upstream with `git pull --ff-only`.
4. Verify that the local branch matches its upstream.

Complete this step when the target branch is checked out and current, the user opted out, or a preserved-worktree blocker has been reported.

## Report

Return:

- pull request URL, initial head, and final tested head;
- one repair-ledger entry per cycle: failed checks, classification, root cause, changed files, verification, commit SHA, pushed head, or rerun;
- final green-check summary;
- merge commit and exact head merged;
- local synchronization result;
- any remaining uncertainty or blocker.

Say explicitly when no CI repairs were needed. Never omit a repair merely because the final CI run passed.
