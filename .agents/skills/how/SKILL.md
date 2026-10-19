---
name: how
description: "Use for \"how does X work\", code walkthroughs before changing something, and placement / ownership / layering questions (\"where should this live\", \"which package owns this\", \"is this the right layer\"). Explains subsystem architecture, runtime flow, onboarding mental models. Use why for motivation."
---

# How

Explore the codebase to answer "how does X work?" questions. Produce an architectural explanation that builds a working mental model without annotating the source file by file.

## Step 1. Assess complexity

If the scope is ambiguous, state your interpretation and explore. The user can redirect.

- **Simple.** A single module, a small utility, or another narrow question needs one explanation pass.
- **Complex.** A subsystem spanning several files or services needs separate exploration angles before synthesis.

When in doubt, take the simple path. Resolve execution through [`HOST-COMPATIBILITY.md`](../../agent-mode/HOST-COMPATIBILITY.md).

## Step 2a. Explore a complex question

Split the question into 2 to 4 distinct angles. Dispatch them as `how-explorer` units. The active profile decides whether the coordinator or read-only workers perform them. Give each unit `references/explorer-prompt.md` with its angle filled in.

## Step 2b. Explain a simple question

Dispatch one shared brief as `how-explainer` with `references/explainer-prompt.md`. Omit the explorer-findings section. The active profile decides whether the coordinator or its configured roster performs the work. Go to Step 4.

## Step 3. Synthesize a complex question

Dispatch the explorer findings as one `how-explainer` brief with `references/explainer-prompt.md`. The coordinator reconciles returned drafts and owns the final explanation.

## Step 4. Present

Present the explanation. Edit only for clarity or relevant conversation context.

Use the sections defined in `references/explainer-prompt.md` and drop any that do not apply: Overview, Key Concepts, How It Works, Where Things Live, Gotchas.
