---
name: reflect
description: "Review a session transcript for durable learnings about skills and the agent's environment (navigation, guardrails, tool economy, steering files), then route each accepted finding to a concrete edit. Use for /reflect, 'reflect', 'retro', or a retrospective on a session."
---

# Reflect

Mine the current conversation for durable learnings, then route them into skill edits.

## When to invoke

- The user said "reflect" or "/reflect".
- A complex task (5+ tool calls) just landed cleanly and the recipe is worth keeping.
- The agent hit dead ends, found the working path, and the path generalizes.
- The user corrected the agent's approach mid-task.
- A non-trivial workflow emerged that isn't captured anywhere.

Skip when the conversation is trivial, off-topic, or already covered by an existing skill the parent followed correctly. One-offs are not learnings.

## Process

Resolve host capabilities and the active profile through [`HOST-COMPATIBILITY.md`](../../agent-mode/HOST-COMPATIBILITY.md) before reading history or delegating.

### 1. Locate the active transcript

Use the active host's task or conversation API when available. Otherwise use only the workspace-scoped transcript location supplied by the host. Never scan unrelated projects. If neither source exists, write a tight digest of the visible session and use that.

```bash
ls -t <agent-transcripts>/*.jsonl <agent-transcripts>/*/*.jsonl <agent-transcripts>/*/subagents/*.jsonl 2>/dev/null | head -10
```

When the host supplies JSONL transcripts, account for flat, nested, and subagent layouts.

For each candidate, read the first JSONL line and check that `message.content[0].text` contains the conversation's opening user prompt. Take the matching path. If no path resolves, write a tight digest of the session and pass that instead.

### 2. Dispatch the review lenses

Dispatch each semantic lens through its role below. Each role receives its shared template; setup alone owns the roster, models, reasoning efforts, and limits. Review workers may need MCP access for cited context, so give them the least-permissive sandbox that preserves those tools. Their prompts forbid file writes; the coordinator applies edits.

| Lens | Role | Prompt template |
|---|---|---|
| Judgment | `reflect-judgment` | `references/judgment-reviewer.md` |
| Tooling | `reflect-tooling` | `references/tooling-reviewer.md` |
| Divergent | `reflect-divergent` | `references/divergent-reviewer.md` |

Pass each template verbatim, substituting the transcript path or digest where marked. Reviewers return findings to the parent task.

### 3. Synthesize

Dispatch the shared synthesis brief as `reflect-synthesizer`. Preserve MCP access when citation checks need it. Use `references/synthesizer.md` verbatim, with every returned review inlined where marked. The coordinator reconciles returned syntheses into a structured Accepted / Rejected / Backlog list.

### 4. Structural enforcement check

Sanity-check the synthesizer's Accepted list. For any prose item that a lint rule, script, metadata flag, hook, CI job, or runtime check would enforce more reliably, change it to a `check:` row, or move it to Backlog when the mechanism is expensive. The synthesizer already applies this criterion; this is a final pass before edits land. See the **encode-lessons-in-structure** principle skill.

### 5. Apply

Before applying any Accepted edit, present the synthesizer's full Accepted/Rejected/Backlog output to the user and wait for explicit approval. The user picks which subset to apply and may redirect routings. Skill changes affect every future agent in the org; do not auto-apply.

Backlog items file to whatever devex / backlog tracker your team uses automatically. Those are tracker submissions, not skill edits. Only the Accepted list waits for approval.

For each approved Accepted item, follow the Routing field exactly:

- Trivial existing-skill edit (a one-line bullet, a tightened sentence, a stale fact corrected): parent does directly.
- Substantive existing-skill edit (a new section, a new pattern table, more than ~10 lines): invoke **skill-creator** and **writing-for-agents**, then run the draft / test / iterate loop.
- `tune description: <skill path>` (the skill exists but didn't trigger when it should have): invoke **skill-creator** and run its description-optimization loop.
- `new skill via skill-creator: <kebab-name>`: invoke **skill-creator**. Do not invent the shape ad hoc.
- `check: <mechanism>`: invoke **correct** for the accepted set. It builds each check and proves it fails on the session's real mistake.
- `steering: <file>`: parent edits directly. Add only a pointer to the doc or skill that holds the detail, or delete the dead instruction.

If your environment ships a SKILL.md validator, run it on every touched skill before declaring done. Skip this step if it doesn't.

### 6. Summarize for the user

Short list, no preamble:

- Edits applied: `<skill path>`. What changed, one line each.
- Checks built and steering edits: `<path>`. One line each.
- New skills created: `<skill path>`. One line each (rare).
- Backlog filed to the devex tracker: `<issue title>` (`<tags>`). One line each.
- Dropped: one line per rejected finding + reason from the synthesizer.
