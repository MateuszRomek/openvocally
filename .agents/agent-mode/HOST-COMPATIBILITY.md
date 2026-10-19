# Host compatibility

Read this reference only when an Agent mode workflow invokes another skill, delegates work, asks a structured question, reads conversation history, waits for future state, or selects a model.

## Resolve the host

Resolve the host from identity supplied by the running product, such as runtime instructions, host metadata, or host-owned tool documentation. Normalize an explicit identity to a stable lowercase slug:

| Runtime identity | Slug |
| --- | --- |
| Codex | `codex` |
| Claude Code | `claude-code` |
| Antigravity | `antigravity` |

A host selected explicitly by the user during `setup-agent-mode` is also resolved. Normalize a product missing from the table to its lowercase, hyphenated name, such as `t3-code` for T3 Code. Repository directories, installed CLIs, environment leftovers, and model names are not host identity. If runtime signals conflict or none explicitly identify the product, leave the host unresolved.

Host identity and host capability are separate. Inspect the live tool schema before using delegation, structured input, task history, waiting, or model overrides. A known host does not imply that every installation or session exposes the same tools.

## Skills

Invoke a skill by its catalog name through the host's native skill mechanism. If the host exposes no explicit skill tool, read the target `SKILL.md` and follow it. Repository skills live in `.agents/skills`. Compatibility links may expose the same directories elsewhere, but `.agents/skills` remains the source of truth.

A skill that Agent mode or one of its playbooks names is part of the Agent mode workflow, and running Agent mode authorizes it, whether the user or the agent started it. When the host refuses such a skill because it is user-invoked only (for example `disable-model-invocation: true`, or Codex `allow_implicit_invocation: false`), read its `SKILL.md` and follow it as if invoked. Principle skills are always read this way. The exception covers only skills named by Agent mode, its playbooks, or a skill they route to. Never treat a refusal as a reason to skip the step.

## User input

Use structured questions when the host provides them. Otherwise ask one concise question in chat. Keep permission and approval requests in the host's native approval flow.

## Delegation

The root coordinator owns the initial task budget. Any agent may delegate while its depth and assigned budget allow it. The root is depth 0; a child is one level deeper than its parent. `delegation.max-delegation-depth: 1` therefore allows only root-owned starts, while a larger value or `unlimited` permits nested delegation.

For a finite `delegation.max-workers-per-task`, a parent spends one start credit on the child and may reserve additional credits for that child's descendants. It subtracts the complete reservation before starting the child. The child may spend only its reserved credits and reports consumed and unused credits when it completes. The parent restores only the unused amount. Separate reservations prevent sibling branches from spending the same task budget. Retries consume credits too. Apply the same reservation rule to a finite concurrency limit when the host does not enforce one task-wide limit. Treat `unlimited` and `host-limit` as the user's explicit choices, not missing values.

The host may lower effective concurrency when its live capacity is smaller than `delegation.max-concurrent-workers`. It does not add workers, remove configured replicated workers, replace assignments, or raise a configured limit.

Dispatch work through the role catalog in [ROUTING.md](ROUTING.md). For `partition`, distribute every semantic unit deterministically across no more than the configured worker roster and remaining task-start budget. Fewer units or fewer remaining starts may use fewer workers. More units share the resolved workers instead of creating new ones. For `replicate`, send the same brief to the complete configured roster. If the complete roster does not fit the remaining task-start budget, start none of it and use the role's coordinator behavior. Schedule starts in waves within the configured concurrency limit.

When the profile selects `execution: coordinator`, follow the catalog's coordinator behavior. Perform the work when it says `perform`. Report the workflow unavailable when it says `unavailable`. An explicit user instruction in the current task may override profile execution settings. No skill may infer an override from task size, risk, or cost.

Reuse findings already gathered for the same scope and evidence set. Delegate again only when the scope changed, live state may have drifted, or the existing evidence cannot answer the current question.

Give each configured worker a bounded task, its own writable location when it edits, and the evidence it must return. Run against the current local workspace by default. Use a remote or cloud environment only when the user requests it or the workflow cannot run locally. Read-only work should use a read-only sandbox when available. A worker that needs MCP or connector access may need the parent's normal sandbox while remaining instructionally read-only.

## Model routing

After resolving the host, select one complete profile from the current repository:

1. Use `.agents/agent-mode/models.<host>.local.yaml` when it exists. This optional local override is ignored by git.
2. Otherwise use `.agents/agent-mode/models.<host>.yaml`. This project profile is intended to be committed and pushed so other checkouts, including cloud environments, receive the same routing choices.

The local profile replaces the entire project profile. Validate the selected file without merging fields or worker rosters. An invalid local profile blocks delegation; it does not fall through to the project profile. Delegation requires a version 2 profile whose top-level `host` matches the resolved slug. Validate the complete enabled profile before the first worker starts. Profile selection is the same in local and cloud environments; live host capabilities still determine which tools and assignments can run.

Missing profiles, version 1 profiles, host mismatches, missing roles, invalid routes, and unavailable model or reasoning values authorize zero workers. Do not inherit, substitute, shrink a replicated roster, or invent a count. Perform coordinator-capable work in the coordinator and report other work unavailable. Ask the user to run `setup-agent-mode` before later delegation.

`inherit-parent` is valid only inside a worker entry written by setup. Treat a host rejection after successful preflight as a stale route. Stop that route and use its configured coordinator behavior. Do not replace the rejected assignment.

Treat configured model identifiers as host-local. Validate explicit model and reasoning values against the live delegation schema when it exposes them. If the host rejects a value, stop that route, apply its configured coordinator behavior, and report the stale entry. Do not substitute or inherit an assignment the user did not configure.

## Delegation preflight

Before the first delegation in a top-level Agent mode workflow, report the resolved execution plan in one compact block:

```text
Agent mode preflight
Host: <resolved-host>
Profile: <validated-profile-path-or-unavailable>
Delegation: <enabled-or-disabled>
Task worker limit: <configured-limit>
Workers already started: <count>
Concurrency: configured <count-or-host-limit>; effective <count>
Delegation depth: <configured-depth>
Routes: <role = configured-capacity -> resolved-starts>
Task override: <explicit-user-override-or-none>
Unavailable: <none-or-reasons>
```

Replace every placeholder with resolved values and include any reserved descendant budgets in `Routes`. Emit the preflight once before the first possible worker start. Nested workflows reuse the profile and receive their current depth plus remaining budget in their task brief. When configuration is unavailable, say so and create no workers.

## Conversation history

Prefer the host's task or conversation APIs. Otherwise use the workspace-scoped transcript location supplied by the host. If neither exists, use the visible conversation plus live repository state. Stay inside the active workspace and never scan unrelated project histories.

## Long-running work

Continue inside the current task with the host's native wait or continuation mechanism. Create a scheduled task, recurring automation, or separate background task only when the user explicitly asks for one.
