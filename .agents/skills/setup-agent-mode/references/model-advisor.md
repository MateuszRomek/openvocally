# Model advisor

Reference for steps 2, 4, and 6 of `setup-agent-mode`. It turns the user's preferences and fresh model research into a role-by-role recommendation.

## Research the host

Use this when the live delegation schema lists no models. Search for the host's documentation on subagents, model selection, and supported providers. Prefer the host vendor's docs, changelog, and configuration reference over third-party posts.

Answer these questions, each with a source link and fetch date:

- Which providers can the host route to? One vendor, or several?
- Which model identifiers does the host accept for a subagent, written exactly as its configuration expects?
- Which reasoning efforts does the host expose, and for which models?
- Can a subagent run a different model or provider from its parent?
- Does the provider set depend on user setup, such as API keys, a subscription, or a local model server?

When the answer depends on user setup, ask the user which providers they have connected. A multi-provider host makes cross-family rosters possible, which strengthens independent review roles.

## Research a candidate

Research every model in the host catalog that the user left eligible. Use primary sources in this order:

1. The vendor's model documentation, model card, and pricing page.
2. The vendor's release notes or launch post for that model version.
3. Independent coding-agent benchmarks that publish their method and date, such as SWE-bench Verified or Terminal-Bench.
4. Community reports, only to break a tie, and labeled as anecdote.

Record one row per model:

| Field | What to capture |
| --- | --- |
| Host identifier | The exact id the host's delegation schema accepts. |
| Price | Input and output per million tokens for API billing, or the plan's usage weight for subscription billing. |
| Context window | Tokens, plus any long-context surcharge. |
| Effort levels | The reasoning efforts the host exposes for this model. |
| Vendor-stated strengths | One line, quoted or paraphrased from the vendor page. |
| Agentic coding evidence | One benchmark score with its source and date, or `none found`. |
| Source links | Every page you read, with the fetch date. |

The research is done when every eligible model has a row and every cell holds a sourced value or `not published`. Spend at most three fetches per model. When web access is unavailable, say so, fill the rows from memory, and label every cell `unverified`.

## Classify each role

Read the `Use` column of `ROUTING.md` and place each role in one demand class. A role that fits none goes in **judgment**.

| Class | Work shape | What decides the model |
| --- | --- | --- |
| **Implementation** | Writes code across several tool calls. Implementation, slices, perf fixes, swarm work. | Correctness on the first attempt. A failed diff costs a review plus a retry. |
| **Judgment** | One answer the coordinator will trust. Synthesis, hardest tasks, blinded judging, explanation. | Reasoning depth. This is where the strongest model earns its price. |
| **Volume reading** | Reads a lot and reports facts. Exploration, evidence gathering, transcripts, research. | Price, speed, and context window. A synthesizer rechecks the facts. |
| **Independent review** | The same brief to several workers. Review, adversarial review, competing candidates, reflection lenses. | Diversity. Different models catch different defects. |
| **Mechanical check** | A narrow, rule-driven pass, such as comment review. | Price. A small model at low effort is usually enough. |

## Heuristics

Label each heuristic as a heuristic when you cite it. Override it when the research rows contradict it.

- **Price the task, not the token.** Task cost is tokens times price times attempts. A cheap model that needs a second attempt, or hands the coordinator a diff to redo, costs more than a strong model that lands it once.
- **Prefer a stronger model at lower effort for implementation.** A frontier model at low effort usually beats a small model at high effort on multi-file code changes. On Claude Code that means Opus at low effort over Haiku at high effort for `feature` or `bug-fix`. Haiku still fits volume reading and mechanical checks.
- **Spend effort on judgment, not on reading.** Raise reasoning effort for judgment roles. Keep volume reading at the lowest effort that still follows instructions.
- **Replicated rosters multiply cost.** A `replicate` role costs its roster length times one worker. Keep these rosters at two or three, and make the entries differ by model family or effort instead of repeating one assignment.
- **The coordinator is a valid economy route.** Under a tight budget, route implementation roles to `coordinator` before routing them to a weak worker.
- **Subscription billing spends rate limits, not dollars.** Heavy models drain the plan's usage window faster. Report the cost column as relative usage for subscription users.
- **Context window gates volume reading.** Pick a model whose window fits the largest artifact the user expects, such as a full transcript or trace.

## Present the recommendation

Show one table with every role from `ROUTING.md`:

| Role | Class | Execution | Model | Effort | Relative cost | Why |
| --- | --- | --- | --- | --- | --- | --- |

Fill `Why` with one clause that cites a research row or a named heuristic. Use `$`, `$$`, and `$$$` for relative cost.

Below the table, show two alternatives as deltas from the recommendation: one cheaper and one stronger. Name the roles that change and what the user gains or gives up. Then list each research source with its fetch date.

When the user's stated preference conflicts with the research, keep the preference in the table and state the tradeoff once in the `Why` cell. The user decides.
