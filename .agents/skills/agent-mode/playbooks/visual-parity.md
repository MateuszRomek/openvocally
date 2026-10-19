### Visual parity

**You own pixel-exact equivalence. The baseline is the spec; you do not touch it.** For "make X match Y exactly", styling-system migrations, porting a UI across frameworks. Equivalence is verified by image diff, not by eye.

1. Establish the baseline first, before any migration: a visual regression harness that screenshots the current component across its states, plus the target when matching two implementations. No baseline, no parity claim. A blocking prerequisite, not a follow-up.
2. Anti-shortcut clauses, stated and held: no harness modifications, no baseline tampering, no component restructuring to make a diff pass. If the baseline looks wrong, stop and ask, don't edit it.
3. Make each component a semantic migration unit and dispatch the units as `feature` through [`HOST-COMPATIBILITY.md`](../../../agent-mode/HOST-COMPATIBILITY.md). Isolate writing workers by worktree (**separate-before-serializing-shared-state**). Shared primitives migrate first as a blocking phase. Setup decides how many workers execute the units.
4. Verify each component against its baseline via image diff on the matching surface via the control skill. A nonzero diff is a fail; investigate the pixel delta, don't wave it through. `/loop` per component until the diff is zero.
5. Finish with verified local changes per component or safe batch. Leave publication to the user's explicit delivery request.

**Reply:** components migrated, the diff result for each, the baseline harness location, what's left.
