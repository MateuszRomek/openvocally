# GitHub stacks

Read this reference only after the user explicitly authorizes commits and pull-request publication for an implementation graph.

## Detect the available path

Inspect the installed tools before changing Git state:

```sh
gh --version
gh extension list
gh stack --help
```

Use the native path only when `gh stack --help` succeeds and the repository can access GitHub's stacked pull-request feature. GitHub's current documentation requires GitHub CLI 2.90.0 or later plus the `github/gh-stack` extension. Treat the working command as the final capability check because the feature and extension are in public preview.

Do not install or upgrade GitHub CLI, add an extension, authenticate, or enable a repository preview without the user's explicit request.

Official references:

- <https://docs.github.com/en/pull-requests/reference/stacked-pull-requests>
- <https://docs.github.com/en/pull-requests/tutorials/stack-code-changes-in-pull-requests>
- <https://github.com/github/gh-stack>

## Native path

Prepare every layer through **prepare-pull-request** first. The bottom pull request targets the normal base branch. Each higher pull request targets the branch directly below it.

After verifying every base and head relationship, register the existing pull requests as a native stack with the supported `gh stack link` form shown by the installed CLI. Read the stack back with `gh stack view` and confirm the order, trunk, pull-request numbers, and branch relationships.

Do not use `gh stack submit` as a shortcut around **prepare-pull-request**. That would bypass the repository's required pull-request body, ticket relationship, readiness check, and final read-back.

## Manual fallback

When native stacks are unavailable, keep the same branch topology with ordinary pull requests:

```text
main <- slice-1 <- slice-2 <- slice-3
```

Create each pull request through **prepare-pull-request** with an explicit base:

- slice 1 targets `main`;
- slice 2 targets the slice 1 branch;
- slice 3 targets the slice 2 branch.

Verify the base and head of every pull request after publication. Report that this is a manual stacked pull-request chain without native GitHub stack metadata.

## Delivery boundary

Stack creation does not authorize merging. Stop after the stack is visible and verified. The user must separately invoke **merge-when-ci-passes** for CI monitoring and merge execution.

The current merge skill operates on one pull request at a time. Until it gains native stack support, process an authorized stack bottom-up and re-resolve each remaining pull request after the lower layer merges.
