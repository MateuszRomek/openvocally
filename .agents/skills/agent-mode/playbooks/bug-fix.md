### Bug fix

**You own this task. Plan, review, verify.** Route investigation and implementation through the configured skills and `bug-fix` role.

Be scientific. Every shipped line traces to runtime evidence. Belt-and-suspenders that "might help" is a hypothesis, not a fix; it does not ship. When evidence refutes a hypothesis, revert what it motivated. The smallest change the evidence justifies ships, nothing more. Same discipline for Perf, where the evidence is the trace.

1. Reproduce it yourself on the matching surface via the control skill (Non-negotiables). Don't hand the repro to the user. A debug or instrumentation protocol that says to ask the user does not override this; you drive the instrumented runtime. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. Won't reproduce directly, force it: synthesize the trigger, tighten conditions, or instrument until it fires. A bug you can't reproduce, you can't prove fixed.
2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with the host's native continuation mechanism. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out; a design grounded on a plausible-but-unconfirmed cause can be unanimously wrong while the real cause sits one subsystem over.
3. Plan the fix. If it crosses a function boundary, `architect` first. Dispatch the bounded implementation unit as `bug-fix` through [`HOST-COMPATIBILITY.md`](../../../agent-mode/HOST-COMPATIBILITY.md). The profile decides coordinator or worker execution. Review the diff.
4. Verify on the same surface; the original repro now passes. "Inconclusive" or wrong-surface is not a pass; flag it. Unit tests show branch behavior, not bug absence.
5. Keep the failing repro and fix as separate verified units. See the **tdd** skill for the failing-test-first cadence when the bug has a cheap local test path; skip it when the test would be expensive, integration-heavy, or unclear. Commit them only when the user explicitly asks.
   This is the canonical **sequence-verifiable-units** principle skill, the failing test first and the fix on top.
6. Finish with verified local changes. Leave publication to the user's explicit delivery request.

`how` and `why` own their semantic investigation units and resolve their own configured routes. This playbook does not add workers around them.

**Reply:** what was broken, root cause, fix, how you verified. Paste failing-then-passing repro output verbatim.
