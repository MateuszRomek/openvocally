---
name: implement-specification
description: Implement a completed product or technical specification as a dependency-aware sequence of small, independently verifiable slices. Use when a Wayfinder, to-spec, or equivalent specification is ready to build across multiple reviewable changes.
---

# Implement specification

Turn one completed specification into a sequence of small changes that a reviewer can understand, verify, and reverse independently. Own the implementation sequence. Keep product discovery and delivery in their existing skills.

## Boundaries

- Start from a settled specification. If a product or architecture decision is still open, return it to **wayfinder** or the user instead of inventing the answer.
- Treat the current model as the coordinator. Resolve every delegated role through the user's version 2 profile. Never infer inheritance, a provider, or a model tier.
- Work locally by default. Staging, committing, pushing, opening pull requests, and merging require explicit current authorization.
- Route pull-request publication through **prepare-pull-request**. Route CI monitoring and merging through **merge-when-ci-passes**. This skill never replaces either workflow.

## 1. Ground the specification

Read the specification, repository instructions, relevant ADRs, domain glossary, current implementation, call sites, tests, public contracts, and migration history.

Build an acceptance matrix that maps every user story or requirement to:

- the owning module or boundary;
- the observable result;
- the verification seam;
- the slice that will implement it.

The matrix is complete when every in-scope requirement has one owner and one observable proof, and every out-of-scope item remains excluded.

## 2. Design the slice graph

Split the work into a directed acyclic graph. Each slice must have:

- one coherent behavior, invariant, or structural outcome;
- explicit dependencies;
- a bounded ownership area;
- a checkable completion predicate;
- focused verification;
- a risk level and review gate.

Prefer the smallest slice that remains useful and independently verifiable. Do not split by file count or an arbitrary line limit. Split when a reviewer would otherwise need unrelated context, when rollback would mix concerns, or when one failure would obscure another.

Classify relationships:

- **Independent.** The slice can start from the target branch and become its own pull request.
- **Dependent.** The slice requires an earlier slice and belongs above it in a stack.
- **Absorbed.** The work is too small to review or verify independently and belongs in its owning slice.

Use **architect** when a slice introduces or changes a boundary, data model, public contract, or module ownership. Use **arena** only when multiple materially different designs remain viable. Use **interrogate** before implementation for contested architecture and after implementation for high-risk slices.

Security-sensitive slices include authentication, authorization, credentials, cryptography, personal data, destructive migrations, external input, and permission boundaries. Give each a focused abuse case, a negative test or executable check, and an adversarial **interrogate** review. Security review is a gate, not a substitute for observable verification.

Present the graph before a long execution unless the user's request already approves executing the completed specification. A graph is ready when every edge represents a real implementation dependency rather than a preferred reading order.

## 3. Implement bottom-up

Process only ready slices whose dependencies are complete.

For each slice:

1. Record its starting state and completion predicate.
2. Apply the narrowest relevant specialist skill.
3. Implement only the slice's owned outcome.
4. Run its focused verification against the real artifact.
5. Inspect the actual diff and affected callers.
6. Mark it `VERIFIED`, `NOT VERIFIED`, or `INCONCLUSIVE` with evidence.

Apply **tdd** only when the user requested it or a bug has an obvious cheap local regression target. Apply **principle-prove-it-works** to every slice and **principle-sequence-verifiable-units** to the whole graph.

Do not start a dependent slice on an unverified base. A changed lower slice invalidates the verification of every dependent slice whose effective diff changed.

Parallelize only independent slices with disjoint ownership. Give each writer an isolated worktree or branch when Git authorization covers creating them. Otherwise work sequentially in the current checkout.

Turn ready implementation slices into semantic units and dispatch them as `feature` through [`HOST-COMPATIBILITY.md`](../../agent-mode/HOST-COMPATIBILITY.md). Dispatch an independent review brief as `reviewer` when the specification requires that evidence. The active profile alone decides whether either role stays with the coordinator or uses workers, and it owns every assignment and limit. Use **interrogate** for adversarial review, **arena** for competing designs, and **swarm** for broad coverage. Only an explicit current-task user instruction overrides the profile.

## 4. Prepare the review stack

This phase runs only when the user explicitly authorizes commits and pull-request publication.

Order verified slices bottom-up. Independent slices target the repository's normal base branch. Dependent slices target the branch directly below them.

Read [GitHub stacks](references/github-stacks.md) before choosing the stack mechanism. Detect the installed GitHub CLI and native stack capability at runtime. Use native GitHub Stacks when available. Otherwise preserve the same branch chain with ordinary pull requests.

Invoke **prepare-pull-request** for every slice so each pull request keeps the repository's required review handoff. Native stack registration happens only after those pull requests exist and their bases are correct.

Stop after publication and report the stack. Monitoring and merging begin only when the user separately invokes **merge-when-ci-passes**.

## Report

Return:

- the specification and acceptance coverage;
- the slice graph in dependency order;
- each slice's verdict and evidence;
- architecture and security gates used;
- local changes, commits, or pull-request links according to the authorized boundary;
- blocked or invalidated slices and the exact reason.
