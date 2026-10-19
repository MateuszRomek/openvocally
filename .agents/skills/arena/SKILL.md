---
name: arena
description: "Run configured competing candidates at the same task, pick a base, and graft the strongest parts of the alternatives into it. Use for /arena, 'arena this', 'throw it in the arena', or when one attempt at a non-trivial artifact would lock in the wrong shape."
---

# Arena

Run the comparison roster configured by setup against the same task. Read every returned candidate end to end. Pick the strongest as the base, graft the best ideas from the others into it, and verify the synthesized result.

## Start

Open a todolist with one entry per phase before launching anything.

1. Frame
2. Fan out
3. Cross-judge
4. Pick
5. Graft
6. Verify

## Phase A: Frame

Every configured candidate receives the same prompt, so the prompt is the contract. Get it right before dispatch.

1. State the artifact each candidate is producing.
2. Derive the rubric. State what success looks like for *this* task, then turn it into 3-6 concrete gradeable criteria. Concrete: `Adds a --dry-run flag that skips writes`. Vague: `code is correct`. The rubric is the picker's tool in Phase D; candidates only see the task.
3. Dispatch the shared candidate brief as `arena-runners` through [`HOST-COMPATIBILITY.md`](../../agent-mode/HOST-COMPATIBILITY.md). Its configured roster is the complete comparison set; this skill never changes its size or assignments.
4. Assign output paths. Each candidate writes to its own location (a git worktree where possible, otherwise a distinct `/tmp/arena-<slug>/candidate-<label>/`). Candidates writing to the same path is shared mutable state and fails the **separate-before-serializing-shared-state** principle skill test.

## Phase B: Fan out

The current coordinator dispatches `arena-runners` within its configured depth and reserved task budget. Give each resolved worker the task, the path to shared grounding, its own output path, and instructions to produce both the artifact and a short rationale. Include any descendant budget reserved for that worker.

The rationale is mandatory. Without it, the parent cannot tell whether a candidate's structure is principled or accidental, which makes Phase E grafting unreliable. Each rationale names the alternatives the candidate considered and what it rejected.

If a candidate fails to produce output, continue with the returned candidates and note the dropout. Do not replace it or shrink the configured roster before dispatch.

## Phase C: Cross-judge

After all Phase B candidates complete, dispatch the shared judgment brief as `arena-cross-judge`. Every resolved judge is read-only, sees the rubric and candidates by path label, scores each criterion, and recommends a base with rationale. The coordinator may read candidates while judges run, but judgment starts only after candidate writes finish.

## Phase D: Pick a base

Read every returned candidate end to end before picking. Skimming favors the candidate whose surface looks most familiar.

Score each candidate against the rubric criterion by criterion, not on holistic feel. Compare against the cross-judge. Agreement on the base confirms the pick. Disagreement means one of you is biased or the rubric was ambiguous. Read both rationales before deciding.

Pick the base on which candidate a future maintainer can extend most easily without breaking invariants. Prefer the cleaner boundary or smaller surface area when two feel tied, per the Laziness Protocol.

Record the pick and the reason in a short synthesis note alongside the base artifact, including the cross-judge's verdict.

## Phase E: Graft

Walk each losing candidate once more and identify what is worth porting into the base. The signal is usually one or two things per candidate, not most of it.

Fold each graft in by hand, per the **redesign-from-first-principles** principle skill. Don't paste mechanically. The result has to remain coherent under one mental model.

Record what was grafted, from which candidate, and what was rejected and why. The rejection notes are the highest-signal part of the record. Future readers learn from what you considered and dropped, not just what you kept.

When the candidates converge on the same shape, that is a strong agreement signal. Note the convergence in the record and ship the consensus shape. No graft is needed. When they wildly diverge, Phase A was under-specified. Reframe and re-run rather than averaging the divergence.

## Phase F: Verify

The synthesized artifact has to hold up under the same scrutiny as any other output, per the **prove-it-works** principle skill. The arena does not earn you a pass.

If verification surfaces a problem the arena did not catch, either Phase A was wrong (re-frame and re-run) or one candidate caught it and you missed the graft (go back to Phase E). Don't paper over.

## Outputs

One synthesized artifact. One short synthesis note alongside, naming the base, the grafts (with source candidate), the rejections, the dropouts if any, and the verification result.
