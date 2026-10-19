# Automated review triage

Read this reference when an explicitly requested review workflow handles comments from a review bot, security agent, or other automated reviewer.

Treat every comment as a claim to verify. Automated reviewers find real defects, but they also report stale assumptions, preferences, duplicate findings, and paths that cannot execute.

## Classify each finding

Assign one outcome after checking the diff and the surrounding code.

- **Fix.** The finding identifies a reachable correctness, security, privacy, authorization, billing, migration, data-loss, idempotency, or concurrency defect.
- **Dismiss.** The claimed path cannot execute, the behavior is intentional and documented by the change, another finding already owns the cause, or the comment is only a style preference.
- **Ask.** The answer depends on product intent, risk acceptance, external ownership, or authority that the repository cannot establish.

Do not fix a comment only to silence the reviewer. Do not dismiss a plausible defect without showing why its execution path is impossible or acceptable.

## Verify the claim

1. Restate the exact failure that the reviewer claims.
2. Trace the input, state, and call path required to reach it.
3. Check the current diff, nearby callers, tests, contracts, and persisted state that govern the path.
4. For a stacked change, inspect the verified parent and child diffs before calling an export, migration step, or temporary state unused.
5. Reproduce the behavior or run the narrowest useful check when the claim is executable.

A type-level possibility is not proof of a runtime defect. A passing test is not proof that an untested path is safe. Base the outcome on the complete path.

## Apply accepted fixes

Fix the root cause at the lowest owner that controls it. Add a focused regression check when the repository has a cheap, stable test path. Otherwise verify the repaired behavior on the same surface that exposed the issue.

Keep unrelated cleanup out of the repair. Re-read the changed diff after the fix and confirm that the original path no longer fails.

## Preserve the delivery boundary

Classifying and repairing findings is local work. Replying to comments, resolving threads, committing, pushing, or updating a pull request requires explicit current authorization and the repository's delivery skill.

## Report

Report each finding with its outcome, the evidence behind that outcome, and any local repair. Separate unresolved product questions from technical blockers.
