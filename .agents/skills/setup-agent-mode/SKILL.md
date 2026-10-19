---
name: setup-agent-mode
description: "Advise on and configure Agent mode model routing: interview model preferences, research current model docs and pricing, recommend the right model and reasoning effort for each role, then write the delegation profile. Use for /setup-agent-mode, configure agent mode, choosing models for agent roles, or changing its execution profile."
---

# Setup Agent mode

Install the shared Agent mode files in the current repository, then write `.agents/agent-mode/models.<host>.yaml` for the current coding-agent host by default. This project profile is intended to be committed and pushed. Write `.agents/agent-mode/models.<host>.local.yaml` only when the user requests a local override. The selected profile is the only persistent source of delegation limits, worker counts, models, reasoning efforts, and inheritance choices. [`assets/agent-mode/ROUTING.md`](assets/agent-mode/ROUTING.md) defines only the stable role names and their work semantics; it contains no execution defaults.

## Steps

### 1. Install the shared Agent mode files

Read [`assets/agent-mode/HOST-COMPATIBILITY.md`](assets/agent-mode/HOST-COMPATIBILITY.md). Copy the contents of `assets/agent-mode` from this skill directory to `.agents/agent-mode` in the current repository. Create the destination when it does not exist. Refresh the shared reference and agent definitions on every run, but preserve every existing `models.*.yaml` profile, including local overrides.

Ensure that the repository ignores `.agents/agent-mode/models.*.local.yaml`. Keep `.agents/agent-mode/models.<host>.yaml` trackable by git. If an ignore rule covers it, narrow that rule or add a profile-specific exception. Do not change unrelated ignore rules.

Complete this step when `.agents/agent-mode/HOST-COMPATIBILITY.md`, `.agents/agent-mode/ROUTING.md`, and both files under `.agents/agent-mode/agents` match the packaged assets.

### 2. Detect the host and available models

Resolve the host through the reference above. If the runtime does not identify itself, ask the user which host runs this session before writing a host-specific file.

The host decides which models exist for this profile. Some hosts route only their own vendor's models, such as Claude Code with Anthropic models and Codex with OpenAI models. Others front several providers, such as T3 Code. Build the host's model catalog from these sources, in order:

1. The live delegation-tool schema or model catalog. It is authoritative.
2. The host's own documentation, when the live schema lists no models. Research it with the host protocol in [`references/model-advisor.md`](references/model-advisor.md).
3. The user, who confirms every identifier that came from documentation, because documentation can lag the installed version.

The catalog is done when you know which providers the host reaches, every assignable model identifier, the reasoning efforts per model, and whether a subagent can run a different model from its parent. If no source yields identifiers, the only eligible worker assignment to propose is `inherit-parent`, and the user must still confirm it. Never write an identifier that neither the live schema nor the user confirmed.

Record which controls the host exposes. These may include model, reasoning effort, concurrency, and a per-agent token budget. Do not promise a control the host cannot enforce. Account count is not a routing field unless the host exposes account selection directly.

### 3. Interview the user about models

Ask before researching or proposing. Use one compact structured question when the host supports it. Otherwise ask concise questions in chat. Skip anything the user already supplied.

Cover these decisions:

- what to optimize for, such as strongest results, balanced quality and cost, lowest practical cost, lowest latency, or a custom split by role;
- how the user pays: API tokens, a subscription plan with usage limits, or both;
- the spend or usage budget and its unit, such as per top-level run, per delegated worker, or per day, when the user has a real limit;
- which host-confirmed models the user prefers, wants for a specific job, or wants excluded, and the reason for each preference;
- whether delegation is enabled at all.

Record each stated preference with its reason. A preference outranks a heuristic in the recommendation.

The interview is done when you know the optimization goal, the billing model, the eligible model set, and every stated preference. Leave limits and rosters to step 6, where you recommend them.

### 4. Research the eligible models

Read [`references/model-advisor.md`](references/model-advisor.md). Research every model in the host catalog that the user left eligible, with the model protocol it defines, then classify every role in `ROUTING.md` into its demand classes. The live host catalog still decides which identifiers are valid. Research decides which valid identifier fits each role.

### 5. Load current state

Choose the write target from the requested scope: the project profile by default, or the local profile when explicitly requested. Load that target when it exists. When it is absent, load the active profile selected by `HOST-COMPATIBILITY.md` as the starting proposal. This lets an existing local profile seed the first project profile without changing its assignments or deleting it.

Show the write target and the active profile separately. If a local override exists while writing a project profile, explain that this checkout will continue using the local override, while checkouts without it will use the project profile.

Treat a version 2 profile as the current proposal to review, not proof that its tradeoffs still match the user's goal. Compare its assignments with the research and flag each one the research no longer supports. Treat every earlier version as unconfigured: it may inform a proposal, but every limit and route must be reconfirmed before writing version 2. Until then, Agent mode starts no workers.

### 6. Recommend and confirm

Present the recommendation in the format `references/model-advisor.md` defines: every role with its class, execution, model, effort, relative cost, and a one-clause reason, followed by a cheaper and a stronger alternative and the research sources. Keep it inside the eligible model set and budget. If the budget cannot support the requested quality, say so and offer the smallest useful adjustment.

Recommend the delegation limits with it:

- the maximum total number of subagent starts in one top-level task, including every nested workflow;
- the maximum number of concurrently active subagents in that task;
- the maximum delegation depth, where `1` allows only root-owned starts and `unlimited` leaves depth unrestricted;
- the roster length of every `workers` route, and any host-supported per-worker budget controls.

Show the write scope and path and mark stale identifiers. Ask the user to confirm or revise the complete profile. Recommendations are proposals, not defaults. Write no limit, roster, model, effort, inheritance, or coordinator route until the user confirms it. `inherit-parent` is valid only when the user explicitly selects it for that roster entry.

### 7. Validate

The file's top-level `host` must equal the resolved host slug. Every explicit model and reasoning effort must be supported by the current host. An explicitly selected `inherit-parent` entry passes structural validation. Reject unavailable combinations before writing. From the repository root, run `python3 .agents/skills/setup-agent-mode/scripts/validate-profile.py <profile-path> .agents/agent-mode/ROUTING.md`. Then run `python3 .agents/skills/setup-agent-mode/scripts/audit-routing.py`. Structural validation checks the version 2 contract; live host validation remains the authority for model identifiers and reasoning efforts.

### 8. Write the rule

Write the confirmed profile to the selected target so reruns stay idempotent. Default to `.agents/agent-mode/models.<host>.yaml`; use `.agents/agent-mode/models.<host>.local.yaml` only for an explicitly requested local override. Preserve the other profile. Use this shape:

```yaml
version: 2
host: <resolved-host-slug>
intent:
  optimization: <confirmed-routing-goal>
  budget: <confirmed-limit-with-unit-or-none>
delegation:
  mode: enabled
  max-workers-per-task: <confirmed-positive-integer-or-unlimited>
  max-concurrent-workers: <confirmed-positive-integer-or-host-limit>
  max-delegation-depth: <confirmed-positive-integer-or-unlimited>
roles:
  feature:
    execution: coordinator
  how-explorer:
    execution: workers
    workers:
      - model: <confirmed-model-id>
        reasoning: <confirmed-reasoning-effort>
  arena-runners:
    execution: workers
    workers:
      - model: <confirmed-model-id>
        reasoning: <confirmed-reasoning-effort>
```

The angle-bracketed values describe the schema. Replace them with user-confirmed, host-validated values. Quote intent strings when YAML could interpret them as another type. Include every role listed in `ROUTING.md` when delegation is enabled. A `coordinator` route has no `workers`. A `workers` route has a non-empty roster, and that list is the complete configured capacity for one invocation of the role. To disable all delegation, keep `intent`, write only `mode: disabled` inside `delegation`, and omit `roles` and all limits. Do not maintain another role list here.

### 9. Confirm

Show the host, delegation mode, optimization goal, budget or cost posture, total task worker limit, concurrency limit, delegation depth, file path, coordinator roles, explicit worker rosters, intentionally inherited entries, and any unavailable combinations rejected during setup. Report which file this checkout will select and whether a local override masks the project profile. Re-running this skill updates only the selected scope for the current host. A project profile is ready for the user's commit and push; setup itself does not stage, commit, or push it.

### 10. Offer a verification skill (optional)

Check whether the project has a way to drive the real app for proof (a `verify-*` skill, or an existing harness). If not, offer once: "want a project-local verification skill, so agents can drive the app the way a user does and prove changes work? I can generate one with /create-verification-skill." On yes, invoke `/create-verification-skill` from its installed location. On no, move on without pushing.
