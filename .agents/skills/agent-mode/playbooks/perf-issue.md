### Perf issue

**You own the measurement story. Plan, review, verify the numbers.** Tie every fix to a measurement, don't read source instead of measuring.

1. Capture a baseline trace via the matching control skill. Vet the baseline, and each later number, with the **benchmark-checklist** skill.
2. `how` to ground hypotheses; don't claim a perf ceiling without running it first.
   Try the performance mantras in order, cheapest first:
   1. Don't do it. Stop work whose result nothing uses rather than cheapening it.
   2. Do it, but don't do it again.
   3. Do it less.
   4. Do it later.
   5. Do it when they're not looking.
   6. Do it concurrently.
   7. Do it cheaper.

   When an earlier mantra meets the target, stop.
3. Plan the fix from the trace. If it crosses a function boundary, `architect` first. Dispatch the bounded implementation unit as `perf-issue` through [`HOST-COMPATIBILITY.md`](../../../agent-mode/HOST-COMPATIBILITY.md). The profile decides coordinator or worker execution. Review the diff and capture a post-fix trace.
   Apply the **sequence-verifiable-units** principle skill, verifying each attempt before trying the next.
4. Parse and compare the artifacts (JSON to sqlite, diff). "Inconclusive" or wrong-surface is not a pass; flag it.
5. Record the measurement for the local handoff and any later pull request.
6. Finish with verified local changes. Leave publication to the user's explicit delivery request.

For sustained improvement against a metric rather than a one-off fix, use the Hillclimb playbook (`playbooks/hillclimb.md`).

**Reply:** baseline number, post-fix number, delta, artifact path.
