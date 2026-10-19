---
name: why
description: "Use for 'why does X work this way', 'why we picked Y', design rationale, regressions, postmortems, or data-backed thresholds. Searches available evidence sources and returns a cited account of decisions and tradeoffs. Use how for runtime behavior."
---

# Why

Investigate the motivation and intent behind code. The `how` skill explains what the code does. This skill explains which constraints and decisions gave it that shape.

## Operating posture

Act as a careful investigator. Separate direct evidence from inference, surface contradictions, and name missing evidence. Read `references/epistemics.md` before synthesis.

## Step 1. Understand the target

Identify the code, pattern, feature, or decision in question. If the target is vague, state the best interpretation from the conversation and proceed.

## Step 2. Establish the code anchor

Before searching other sources, collect:

- the relevant paths, lines, and symbols;
- recent commits that touched them;
- pull request and ticket identifiers from those commits.

Use the repository's own history and forge tools. Typical commands include:

```bash
git blame -L <start>,<end> <file>
git log --follow -p -- <file>
git log --oneline -20 -- <file>
git log -1 --format=%B <commit>
```

Fetch the body and discussion for substantive pull requests. Pass the resulting code anchor to every evidence search.

## Step 3. Search the available evidence

Resolve host capabilities and the active profile through [`HOST-COMPATIBILITY.md`](../../agent-mode/HOST-COMPATIBILITY.md). Inspect live tools, MCP servers, connectors, and shared resources.

Map each available source to one category:

1. source control history;
2. issue or ticket tracking;
3. long-form documents;
4. real-time team chat;
5. infrastructure observability;
6. error tracking;
7. product analytics.

Source control is always available. Record missing categories instead of pretending they were searched.

Create a semantic unit for every available category. Dispatch the units as `why-investigators` through the active profile. Its partition rule may assign several units to a worker. Keep the units distinct and instructionally read-only.

Each unit receives:

1. `references/investigator-prompt.md`;
2. the matching playbook under `references/sources/`;
3. `references/sources/incident-postmortem.md` when the target contains defensive runtime behavior;
4. the code anchor;
5. the user's question.

### Evidence categories

- **Source control.** Git history, pull requests, comments, tests, and repository documents. This is the only guaranteed source.
- **Issue tracker.** Product or business constraints recorded in tickets.
- **Long-form documents.** Design rationale in specifications, ADRs, and postmortems.
- **Team chat.** Deliberation that never reached a durable document.
- **Infrastructure observability.** Runtime conditions that motivated limits, retries, timeouts, or similar defenses.
- **Error tracking.** Specific failures that motivated corrective code.
- **Product analytics.** Usage or data distributions that shaped behavior and thresholds.

### Skipping a category

Skip a category only when no matching source is available or the source is demonstrably irrelevant. Record the reason in the final coverage map. A null search result is evidence. An unsearched source is a gap.

A single-commit question may stay inline when the pull request already contains the full answer and the other available categories would add no evidence. State that scope choice.

## Step 4. Synthesize

Dispatch one shared brief as `why-synthesizer`. Give it:

1. every result and recorded gap;
2. the code anchor;
3. the user's question;
4. `references/epistemics.md`;
5. `references/synthesizer-prompt.md`.

The active profile decides whether the coordinator or workers perform synthesis. The coordinator checks citations, reconciles returned drafts, and owns the final answer.

## Step 5. Present

Preserve the synthesizer's confidence labels. Use the structure in `references/synthesizer-prompt.md`: The Question, The Code in Question, What We Found, What We Can Reasonably Infer, Competing Hypotheses, What We Don't Know, Sources Consulted, Confidence Summary.

If the user may change the code next, finish with Preserve, Change, Avoid, and Risk constraints.

## Failure mode

Do not assume the newest commit explains the current design. Trace the history far enough to identify the decision that introduced the behavior.

## References

- `references/epistemics.md` defines confidence levels.
- `references/investigator-prompt.md` defines the evidence-search brief.
- `references/source-playbook.md` maps evidence categories to source playbooks.
- `references/sources/*.md` contains one playbook per source category and the defensive-code supplement.
- `references/synthesizer-prompt.md` defines synthesis and output.
