---
name: prepare-pull-request
description: Prepare, open, or update a GitHub pull request for review. Use when the user asks to prepare, publish, create, open, or make a pull request ready for review.
---

# Prepare Pull Request

Treat the pull request as a briefing a reviewer can read in under a minute. Explain why the change exists, what it changes, what it can affect, and how you proved it works. Keep detailed logs in linked artifacts.

## 1. Establish the handoff

1. Proceed only after the user explicitly asks to prepare, open, publish, or update a pull request. That request authorizes the Git delivery needed for the pull request, but not merging it.
2. Inspect the branch, complete diff, commits, and validation results. Derive every statement in the pull request body from those facts.
3. Identify the ticket being delivered from the user's request, branch context, commits, or tracker. If the ticket is ambiguous, fetch the plausible ticket before writing the body; ask the user only when the ambiguity remains material.

Complete this step when the change, its validation, and its ticket relationship are known well enough to write a factual review handoff.

## 2. Write the pull request body

Use these sections in order. Drop Tradeoffs when no real choice needs explanation.

```md
## Why

<State the intent and approach in one or two short paragraphs.>

## Scope

<The smallest sketch that shows the change: a diff-sketch, call tree, file tree, or Mermaid diagram. Use bullets of symbols and paths when no shape matters.>

- <State an important exclusion when the boundary matters.>

## Tradeoffs

<Name only a rejected alternative that a reviewer would otherwise ask about.>

## Blast radius

**Door:** <one-way or two-way>

<In one to three sentences, name what the change touches and why it is safe or risky.>

## Verification

- **Before:** <the failing test, wrong output, or screenshot on the base branch>
  **After:** <the same check passing on this branch>
- <Name any other check that ran and its observed result.>

## References

Closes #<issue-number>
```

- Keep the body near 40 lines or fewer. The squash commit may reuse it.
- Keep Why, Scope, Blast radius, Verification, and References. Include Tradeoffs only for a real decision.
- Pick the Scope sketch per [`references/scope-sketches.md`](references/scope-sketches.md). Show only the calls, files, components, or states a reviewer needs. Do not write a file-by-file account.
- Mark the change a **one-way door** when it is hard to walk back: a data migration, a deletion, a published API or schema, a destructive operation. Everything a revert fully undoes is a **two-way door**.
- Prefer Before/After evidence a reviewer can see. A screenshot beats execution output for a visual change. Execution output, such as the exact test that failed and now passes, beats a description. For a performance change, report the primary before and after value with its unit. Drop Before when no prior behavior existed.
- Report checks that actually ran and their outcomes. Include a command, route, or user action when it helps a reviewer reproduce the result.
- Match the changed paths against the quality gates in the repository's agent instruction file (`CLAUDE.md` or `AGENTS.md`), such as motion, scene or menu changes, hot-path latency, and security. List each gate the diff triggers under Verification as run, with its result, or skipped, with the reason. Recheck a skip decided earlier in the task against the final diff.
- Link detailed measurements, screenshots, or decision logs. Do not paste full SHAs, agent transcripts, lane summaries, large metric tables, or generic verdicts.
- For a GitHub issue in the same repository, put `Closes #<issue-number>` in **References** exactly. This is the closing keyword that makes GitHub close the issue after the pull request is merged into its target branch; a bare `#<issue-number>` is not enough.
- For a ticket outside GitHub or in another repository, include its canonical reference in **References**. Do not claim it will close automatically.
- If no ticket applies, retain **References** and write `No ticket.` Do not invent an issue reference.

Complete this step when every retained section is factual and the reference either has a valid closing keyword or explicitly states that no ticket applies.

## 3. Publish for review

1. Create a new pull request as a non-draft by default. Use `--draft` only when the user directly requests a draft pull request.
2. If an existing pull request on the branch is a draft and the user did not directly request it remain a draft, update its body and mark it ready for review.
3. Set the requested base branch; otherwise use the repository's normal default branch. Preserve the branch and complete diff unless the user directs a narrower scope.
4. After publishing, read the pull request and verify its target branch, body, URL, and review state. The normal completion state is open and non-draft (`isDraft: false`).

Complete this step only when GitHub shows the pull request with the required body and state. Report its URL, state, verification, and linked ticket.
