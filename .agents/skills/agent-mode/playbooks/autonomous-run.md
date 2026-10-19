### Autonomous run

**You own the exit condition. Define done, then drive to it without stopping.** For "going to bed" / "run until done" / "/loop until X".

1. State the exit condition as a checkable predicate before the first iteration (tests green, repro fixed, all N units verified, pixel-diff zero). A vague goal stalls; a predicate lets you stop.
2. Pick the host's native wait or continuation mechanism. An event to watch (CI, a merge, a ref advancing) gets an event-aware wait when available, with bounded polling as fallback. Keep it inside the current task unless the user explicitly requests scheduling or a separate task.
3. Each iteration makes the smallest change the evidence justifies, verifies it against the predicate, keeps it if it advanced, and discards changes that didn't help. Commit only when the user explicitly asks. Belt-and-suspenders that "might help" gets reverted, not left to ride.
   Sequence the work via the **sequence-verifiable-units** principle skill, verifying each unit before the next instead of batching checks at the end.
4. Mid-run discoveries are yours. Address broken skills, related bugs, flaky verifiers, review noise, tooling failures, orphaned follow-ups, and fixable drift yourself via Agent mode. Keep out-of-band fixes as separate local units. Do not park reversible work for the human. Surface only irreversible actions, genuine product or preference calls no experiment can settle, or a real dead end. Keep the predicate as the main drive, and return to it after each side fix.
5. Checkpoint every iteration via the **show-me-your-work** skill, a row for what changed and whether the predicate moved. A run with no trail can't be audited or resumed.
6. Stop when the predicate is met. A plateau is not a stop, so keep going and pivot your approach to push past it. Surface a genuine dead end rather than spinning, and never relax the predicate to declare victory.

**Reply:** the exit condition, iterations run, what changed, what was discarded, final predicate state.
