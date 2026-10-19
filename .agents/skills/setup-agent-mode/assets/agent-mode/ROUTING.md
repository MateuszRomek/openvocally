# Agent mode routing

This file is the source of truth for Agent mode work roles. Setup reads it when proposing a profile. Workflows use it when dispatching semantic work.

## Policy

Setup records execution policy in the selected host profile. This catalog contains no worker count, model, reasoning effort, concurrency value, or fallback.

Each role has a dispatch behavior. `partition` distributes distinct work units across the configured roster. `replicate` sends the same brief to every configured worker. The behavior describes the work, never its size.

## Roles

`Coordinator` says what happens when setup configures the role with `execution: coordinator`. `perform` keeps the work in the coordinator. `unavailable` means the workflow cannot claim its independent comparison or fan-out contract and reports that limitation.

| Role | Dispatch | Coordinator | Use |
| --- | --- | --- | --- |
| `feature` | partition | perform | Feature implementation and specification slices. |
| `refactoring` | partition | perform | Behavior-preserving structural edits. |
| `bug-fix` | partition | perform | Bug investigation and implementation. |
| `perf-issue` | partition | perform | Performance diagnosis and implementation. |
| `hillclimb` | partition | perform | Measured optimization iterations. |
| `judgment-prose` | replicate | perform | Prose evaluation or synthesis when no narrower role applies. |
| `hardest-tasks` | partition | perform | Ambiguous, cross-cutting, concurrent, or algorithmic work when no narrower role applies. |
| `bulk-reader` | partition | perform | Long transcripts, traces, feature corpora, or other large read-only artifacts. |
| `comment-sicko` | replicate | perform | Comment review in `no-comments`. |
| `reviewer` | replicate | unavailable | Independent review without a specialist review role. |
| `how-explorer` | partition | perform | `how` source exploration. |
| `how-explainer` | replicate | perform | `how` explanation and synthesis. |
| `why-investigators` | partition | perform | `why` evidence-source investigation. |
| `why-synthesizer` | replicate | perform | `why` synthesis. |
| `reflect-tooling` | replicate | perform | Tooling review in `reflect`. |
| `reflect-judgment` | replicate | perform | Judgment review in `reflect`. |
| `reflect-divergent` | replicate | perform | Divergent review in `reflect`. |
| `reflect-synthesizer` | replicate | perform | Accepted, rejected, and backlog synthesis in `reflect`. |
| `arena-runners` | replicate | unavailable | Competing `arena` candidates. |
| `arena-cross-judge` | replicate | unavailable | Blinded `arena` judgment. |
| `swarm-worker` | partition | unavailable | Work assigned by `swarm`. |
| `architect-runners` | replicate | unavailable | Competing architecture candidates. |
| `interrogate-reviewers` | replicate | unavailable | Adversarial review. |
| `researcher` | partition | perform | Research questions and evidence gathering. |

## Selection

Use the narrowest matching role. A workflow submits semantic units for `partition` or one shared brief for `replicate`. The selected host profile is the only source of execution mode, worker roster, model, reasoning effort, task budget, concurrency, and delegation depth. A current-task override exists only when the user states it explicitly.
