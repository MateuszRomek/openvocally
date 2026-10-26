# OpenVocally verification map

This folder is the maintained source for verifying what an OpenVocally user sees and does. Read this index, run the doctor, then follow the matching feature file.

## Baseline preconditions

- Run `.agents/skills/verify-openvocally/doctor.sh` from the repo root. It must exit 0.
- At least one speech model is installed for dictation checks. The doctor lists them.
- This terminal has Screen Recording for any screenshot check.
- Never drive a Debug app that a script of this run did not start, and never touch the installed Release app.

## Driving conventions

- Drive the app only through the scripts and launch arguments named here. Never post clicks or keys: the user may be typing on this Mac.
- Every script holds the Debug app lock. Run one at a time, or let them queue on the lock.
- Run every command from the repo root. Treat commands as literal.

## Proof and skip reporting

- Report the command, its exit code and the evidence path for each feature.
- Open each PNG you cite and say what it shows.
- For dictation, quote the text and the LB-01 and LB-02 rows from `latency.txt`.
- When a precondition is missing (no model, no Screen Recording), report the feature as not verified with the doctor line that blocked it. Don't verify it through another path and call it the same.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph on the user-visible behavior, then four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with the scripts`, `Gotchas`.

## Features

- [Dictation](./dictation.md) covers hold and toggle dictation from press to pasted text, the latency budgets and the history save.
- [Overlay](./overlay.md) covers the recording overlay's states, styles, placements and full-screen apps.
- [Notch](./notch.md) covers the Debug-only dictation notch: every scene, appearance and Reduce Motion, on every display.
- [Transcripts](./transcripts.md) covers Home and Transcripts on a large history: open, scroll, select, sidebar and minimum width.
- [Onboarding](./onboarding.md) covers each first-run step.
- [Design Gallery](./design-gallery.md) covers the design tokens and components in light, dark and Increase Contrast.
- [Idle health](./idle-health.md) covers CPU use while the app sits idle.
