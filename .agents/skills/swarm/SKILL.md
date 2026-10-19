---
name: swarm
description: "Dispatch configured workers over coverage slices or a shared race brief, drain them, and return one report. Use for /swarm, 'swarm this', or parallel coverage, races, gauntlets, and exploration."
---

# Swarm

Dispatch semantic work through the setup-owned `swarm-worker` route. Workers may cover separate slices or receive a shared race brief. The coordinator waits, aggregates, and returns one report.

## Start

Open a todolist with one entry per phase before launching anything.

1. Frame
2. Fan out
3. Aggregate
4. Report

## Phase A: Frame

1. State the done predicate and the artifact or report the swarm must return.
2. Choose the semantic shape: distinct coverage slices or one shared race brief. For a race, declare `first pass`, `rank all`, or `best-of` before dispatch.
3. Dispatch `swarm-worker` through [`HOST-COMPATIBILITY.md`](../../agent-mode/HOST-COMPATIBILITY.md). Setup owns its roster, assignments, and limits; the skill never derives them from the shape.
4. Give each resolved worker its own writable output when it writes. Use a worktree, branch, or distinct `/tmp/swarm-<slug>/worker-<label>/`. When workers verify or measure commits, each brief names the exact SHAs. A measurement brief also names the method (sample count, what one sample is, order). The worker records both in its result.

## Phase B: Fan out

The current coordinator schedules the resolved roster within its configured depth and reserved task budget. Use the current local workspace by default. Use a remote environment only when the user requests it or local execution cannot satisfy the task. Include any descendant budget reserved for each worker.

Every brief stands alone. Include the goal, scope, exact slice or race arm, how to verify, and what to report. Reports use `PASS`, `ISSUES`, or `BLOCKED` with evidence. A worker that can prove a defect reports `ISSUES` and lists every issue it can prove, not only the first.

If a worker drops out, continue with the returned results and note it. Do not replace the worker.

## Phase C: Aggregate

Read the terminal results. Drop a result that does not record the SHAs and method its brief names, and dispatch that brief once more through the same route when the reserved budget allows. Retries consume credits. After a second miss, record a gap. A gap does not count as a pass. For coverage, every required slice needs a result. For a race, apply the selection rule declared up front. Use first pass, rank all, or best-of. Do not paste raw worker dumps.

Keep a compact result table, one-line evidenced issues, and explicit gaps or dropouts.

## Phase D: Report

Return one consolidated in-chat report with the table, issue one-liners, gaps or dropouts, and the race rule when used.
